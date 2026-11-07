import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import ChitgramCore
import ChitgramEngine

/// Wheel pickers of the auto messenger (Android `AutoPostPickers`), as action sheets: an interval as hours and
/// minutes, active hours as "from" and "to", and one time of day.
private final class ChitgramWheelActionSheetItem: ActionSheetItem {
    enum Kind {
        /// Hours and minutes, in steps of 5 minutes.
        case interval(minutes: Int)
        /// One time of day, in minutes since midnight.
        case time(minutes: Int)
        /// Two hours of the day.
        case hours(start: Int, end: Int)
    }

    let kind: Kind
    let valueChanged: (Int, Int) -> Void

    init(kind: Kind, valueChanged: @escaping (Int, Int) -> Void) {
        self.kind = kind
        self.valueChanged = valueChanged
    }

    func node(theme: ActionSheetControllerTheme) -> ActionSheetItemNode {
        return ChitgramWheelActionSheetItemNode(theme: theme, item: self)
    }

    func updateNode(_ node: ActionSheetItemNode) {
    }
}

private final class ChitgramWheelActionSheetItemNode: ActionSheetItemNode, UIPickerViewDataSource, UIPickerViewDelegate {
    private let theme: ActionSheetControllerTheme
    private let item: ChitgramWheelActionSheetItem
    private var datePicker: UIDatePicker?
    private var pickerView: UIPickerView?

    init(theme: ActionSheetControllerTheme, item: ChitgramWheelActionSheetItem) {
        self.theme = theme
        self.item = item
        super.init(theme: theme)
    }

    override func didLoad() {
        super.didLoad()

        let style: UIUserInterfaceStyle = self.theme.backgroundType == .dark ? .dark : .light
        switch self.item.kind {
        case let .interval(minutes):
            let picker = UIDatePicker()
            picker.overrideUserInterfaceStyle = style
            picker.datePickerMode = .countDownTimer
            picker.preferredDatePickerStyle = .wheels
            picker.minuteInterval = 5
            picker.countDownDuration = TimeInterval(max(5, minutes) * 60)
            picker.addTarget(self, action: #selector(self.datePickerChanged), for: .valueChanged)
            self.view.addSubview(picker)
            self.datePicker = picker
        case let .time(minutes):
            let picker = UIDatePicker()
            picker.overrideUserInterfaceStyle = style
            picker.datePickerMode = .time
            picker.preferredDatePickerStyle = .wheels
            picker.locale = Locale(identifier: "en_GB")
            let calendar = Calendar.current
            picker.date = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            picker.addTarget(self, action: #selector(self.datePickerChanged), for: .valueChanged)
            self.view.addSubview(picker)
            self.datePicker = picker
        case let .hours(start, end):
            let picker = UIPickerView()
            picker.overrideUserInterfaceStyle = style
            picker.dataSource = self
            picker.delegate = self
            picker.selectRow(start, inComponent: 0, animated: false)
            picker.selectRow(end, inComponent: 1, animated: false)
            self.view.addSubview(picker)
            self.pickerView = picker
        }
    }

    @objc private func datePickerChanged() {
        guard let picker = self.datePicker else {
            return
        }
        switch self.item.kind {
        case .interval:
            self.item.valueChanged(Int(picker.countDownDuration / 60.0), 0)
        case .time:
            let components = Calendar.current.dateComponents([.hour, .minute], from: picker.date)
            self.item.valueChanged((components.hour ?? 0) * 60 + (components.minute ?? 0), 0)
        case .hours:
            break
        }
    }

    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 2
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return 24
    }

    func pickerView(_ pickerView: UIPickerView, attributedTitleForRow row: Int, forComponent component: Int) -> NSAttributedString? {
        return NSAttributedString(string: String(format: "%02d:00", row), attributes: [.foregroundColor: self.theme.primaryTextColor])
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        self.item.valueChanged(pickerView.selectedRow(inComponent: 0), pickerView.selectedRow(inComponent: 1))
    }

    override func updateLayout(constrainedSize: CGSize, transition: ContainedViewLayoutTransition) -> CGSize {
        let size = CGSize(width: constrainedSize.width, height: 216.0)
        let frame = CGRect(origin: CGPoint(), size: size)
        self.datePicker?.frame = frame
        self.pickerView?.frame = frame
        self.updateInternalLayout(size, constrainedSize: constrainedSize)
        return size
    }
}

/// "From … to …" labels above the hour wheels.
private func chitgramHoursCaption() -> String {
    return "\(ChitgramStrings.get(503))  ·  \(ChitgramStrings.get(504))"
}

/// The interval sheet: never below `minMinutes`. A shorter pick is raised to the minimum, and the sheet says why
/// (on the free plan with the way to Premium, as on Android).
func chitgramPresentIntervalPicker(presentationData: PresentationData, currentMinutes: Int, minMinutes: Int, isPremium: Bool, present: (ViewController) -> Void, openPremium: @escaping () -> Void, picked: @escaping (Int) -> Void) {
    let actionSheet = ActionSheetController(presentationData: presentationData)
    var value = max(currentMinutes, minMinutes)
    let hint: String
    if isPremium {
        hint = ChitgramStrings.format(549, chitgramAutoPostInterval(minMinutes))
    } else {
        hint = ChitgramStrings.format(548, chitgramAutoPostInterval(minMinutes), chitgramAutoPostInterval(ChitgramAutoPost.premiumMinInterval))
    }
    var items: [ActionSheetItem] = [
        ActionSheetTextItem(title: ChitgramStrings.get(474), font: .large, parseMarkdown: false),
        ChitgramWheelActionSheetItem(kind: .interval(minutes: value), valueChanged: { minutes, _ in
            value = minutes
        }),
        ActionSheetTextItem(title: hint, parseMarkdown: false)
    ]
    if !isPremium {
        items.append(ActionSheetButtonItem(title: "\u{1F48E} \(ChitgramStrings.get(520))", color: .accent, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            openPremium()
        }))
    }
    items.append(ActionSheetButtonItem(title: presentationData.strings.Common_Save, color: .accent, font: .bold, action: { [weak actionSheet] in
        actionSheet?.dismissAnimated()
        picked(max(value, minMinutes))
    }))
    actionSheet.setItemGroups([
        ActionSheetItemGroup(items: items),
        ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])
    ])
    present(actionSheet)
}

/// Active hours: "from" and "to"; the same hour on both means all day.
func chitgramPresentHoursPicker(presentationData: PresentationData, startHour: Int, endHour: Int, present: (ViewController) -> Void, picked: @escaping (Int, Int) -> Void) {
    let actionSheet = ActionSheetController(presentationData: presentationData)
    var start = startHour
    var end = endHour
    actionSheet.setItemGroups([
        ActionSheetItemGroup(items: [
            ActionSheetTextItem(title: ChitgramStrings.get(475), font: .large, parseMarkdown: false),
            ActionSheetTextItem(title: chitgramHoursCaption(), parseMarkdown: false),
            ChitgramWheelActionSheetItem(kind: .hours(start: startHour, end: endHour), valueChanged: { from, to in
                start = from
                end = to
            }),
            ActionSheetButtonItem(title: presentationData.strings.Common_Save, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                picked(start, end)
            })
        ]),
        ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])
    ])
    present(actionSheet)
}

/// One time of day, in minutes since midnight.
func chitgramPresentTimePicker(presentationData: PresentationData, title: String, currentMinutes: Int, present: (ViewController) -> Void, picked: @escaping (Int) -> Void) {
    let actionSheet = ActionSheetController(presentationData: presentationData)
    var value = currentMinutes
    actionSheet.setItemGroups([
        ActionSheetItemGroup(items: [
            ActionSheetTextItem(title: title, font: .large, parseMarkdown: false),
            ChitgramWheelActionSheetItem(kind: .time(minutes: currentMinutes), valueChanged: { minutes, _ in
                value = minutes
            }),
            ActionSheetButtonItem(title: presentationData.strings.Common_Save, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                picked(value)
            })
        ]),
        ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])
    ])
    present(actionSheet)
}
