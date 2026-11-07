import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import ChitgramCore

/// Notices the owner gives every copy of the app from the @chitgram_org channel's pins (Android `update/AppUpdate`,
/// `MaintenanceView`). Each notice is a line of its own in a pin:
///
///     texnik ishlar               maintenance: a full-screen "technical work" screen (shared with Android)
///     texnik ishlar: 18:00 gacha  the same, with the owner's note
///     ios majburiy 13.1.3         iOS builds below 13.1.3 are blocked until updated
///     ios yangilanish 13.1.3      iOS builds below it are offered the update, at most once a day
///     https://…                   where "Update" leads; the channel otherwise
///
/// The update lines carry "ios" because iOS and Android version numbers differ; Android's own lines start with the
/// notice word, so neither app reads the other's. English and Russian words work too. Maintenance read more than a
/// day ago lapses, so a copy that cannot reach the channel is never locked for good.
public enum ChitgramAppNotices {
    private static let start = "^[^\\p{L}\\p{N}]*"
    private static let version = "\\s*:?\\s*v?(\\d+(?:\\.\\d+){1,3})\\b"
    private static let maintenance = start + "(?:texnik ishlar|texnik ish|maintenance|технические работы)\\s*(?::\\s*(.*))?$"
    private static let androidRequired = start + "(?:majburiy|required|обязательно)" + version
    private static let androidLatest = start + "(?:yangilanish|update|обновление)" + version
    private static let required = start + "ios\\s+(?:majburiy|required|обязательно)" + version
    private static let latest = start + "ios\\s+(?:yangilanish|update|обновление)" + version
    private static let link = "https?://\\S+"
    private static let channelUrl = "https://t.me/chitgram_org"
    private static let maintenanceTrust: Double = 24 * 60 * 60
    private static let remindInterval: Double = 24 * 60 * 60

    private static var defaults: UserDefaults {
        return ChitgramPreferences.shared.userDefaults
    }

    private static func firstMatch(_ pattern: String, in line: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let text = line.trimmingCharacters(in: .whitespaces)
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }
        var groups: [String] = []
        for index in 0 ..< match.numberOfRanges {
            let groupRange = match.range(at: index)
            groups.append(groupRange.location == NSNotFound ? "" : (text as NSString).substring(with: groupRange))
        }
        return groups
    }

    private static func isNotice(_ line: String) -> Bool {
        return [self.maintenance, self.androidRequired, self.androidLatest, self.required, self.latest].contains(where: { self.firstMatch($0, in: line) != nil })
    }

    /// The pin without its notice lines and links, for the price parser, which must see only the prices.
    public static func stripDirectives(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).filter { !self.isNotice($0) }
        let joined = lines.joined(separator: "\n")
        guard let regex = try? NSRegularExpression(pattern: self.link) else {
            return joined
        }
        return regex.stringByReplacingMatches(in: joined, range: NSRange(location: 0, length: (joined as NSString).length), withTemplate: " ")
    }

    /// The channel's pins were just read: each notice comes from the newest pin that has it; a notice in no pin is
    /// lifted.
    public static func apply(_ posts: [ChitgramChannelPost]) {
        let pins = posts.sorted(by: { $0.date > $1.date }).map { $0.text.components(separatedBy: .newlines) }
        func find(_ pattern: String) -> [String]? {
            for pin in pins {
                for line in pin {
                    if let groups = self.firstMatch(pattern, in: line) {
                        return groups
                    }
                }
            }
            return nil
        }
        let maintenance = find(self.maintenance)
        var url: String?
        for post in posts.sorted(by: { $0.date > $1.date }) where post.text.components(separatedBy: .newlines).contains(where: { self.isNotice($0) }) {
            if let groups = self.firstMatch(self.link, in: post.text.replacingOccurrences(of: "\n", with: " ")), let first = groups.first {
                url = first
                break
            }
        }
        self.defaults.set(Date().timeIntervalSince1970, forKey: "chitgram_update_read_at")
        self.defaults.set(maintenance != nil, forKey: "chitgram_update_maintenance")
        self.defaults.set(maintenance.flatMap { $0.count > 1 ? $0[1].trimmingCharacters(in: .whitespaces) : nil }, forKey: "chitgram_update_maintenance_note")
        self.defaults.set(find(self.required).flatMap { $0.count > 1 ? $0[1] : nil }, forKey: "chitgram_update_required")
        self.defaults.set(find(self.latest).flatMap { $0.count > 1 ? $0[1] : nil }, forKey: "chitgram_update_latest")
        self.defaults.set(url, forKey: "chitgram_update_url")
    }

    private static var currentVersion: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Version strings compared number by number: 1.0.10 is above 1.0.9, and 1.0 equals 1.0.0.
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == " " }).map { Int($0) ?? 0 }
        let right = rhs.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == " " }).map { Int($0) ?? 0 }
        for index in 0 ..< max(left.count, right.count) {
            let difference = (index < left.count ? left[index] : 0) - (index < right.count ? right[index] : 0)
            if difference != 0 {
                return difference
            }
        }
        return 0
    }

    /// The owner's note while maintenance is on ("" without one); nil when it is off or has lapsed.
    static func maintenanceNote() -> String? {
        if !self.defaults.bool(forKey: "chitgram_update_maintenance") {
            return nil
        }
        if Date().timeIntervalSince1970 - self.defaults.double(forKey: "chitgram_update_read_at") > self.maintenanceTrust {
            return nil
        }
        return self.defaults.string(forKey: "chitgram_update_maintenance_note") ?? ""
    }

    static func requiredVersion() -> String? {
        guard let version = self.defaults.string(forKey: "chitgram_update_required"), self.compare(self.currentVersion, version) < 0 else {
            return nil
        }
        return version
    }

    private static func openUpdate(context: AccountContext) {
        let url = self.defaults.string(forKey: "chitgram_update_url") ?? self.channelUrl
        context.sharedContext.applicationBindings.openUrl(url)
    }

    // MARK: Showing it

    private static weak var shownController: ChitgramNoticeController?
    private static var shownKind: String?

    /// Puts the current answer on screen, most serious first: maintenance, a required update, then the daily offer
    /// of a newer version; and takes away a screen of ours that no longer applies. Run at launch, on every return
    /// to the app and after each read of the pins.
    public static func show(context: AccountContext) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        if let note = self.maintenanceNote() {
            let text = note.isEmpty ? ChitgramStrings.get(596) : ChitgramStrings.get(596) + "\n\n" + note
            self.present(context: context, kind: "maintenance", controller: ChitgramNoticeController(theme: presentationData.theme, title: ChitgramStrings.get(595), text: text, buttonTitle: ChitgramStrings.get(597), action: { controller in
                controller.setButtonTitle(ChitgramStrings.get(444))
                let _ = (ChitgramPremium.refreshPlans(context: context)
                |> deliverOnMainQueue).startStandalone(completed: {
                    controller.setButtonTitle(ChitgramStrings.get(597))
                    self.show(context: context)
                })
            }))
            return
        }
        if let version = self.requiredVersion() {
            self.present(context: context, kind: "required", controller: ChitgramNoticeController(theme: presentationData.theme, title: ChitgramStrings.get(151), text: ChitgramStrings.format(590, version), buttonTitle: ChitgramStrings.get(593), action: { _ in
                self.openUpdate(context: context)
            }))
            return
        }
        if let controller = self.shownController {
            controller.dismiss()
            self.shownController = nil
            self.shownKind = nil
        }
        self.offer(context: context)
    }

    private static func present(context: AccountContext, kind: String, controller: ChitgramNoticeController) {
        if self.shownController != nil && self.shownKind == kind {
            return
        }
        self.shownController?.dismiss()
        self.shownController = controller
        self.shownKind = kind
        context.sharedContext.mainWindow?.present(controller, on: .root)
    }

    /// "A new version is out", once a day at most, while one is announced and not installed.
    private static func offer(context: AccountContext) {
        guard let latest = self.defaults.string(forKey: "chitgram_update_latest"), self.compare(self.currentVersion, latest) < 0 else {
            return
        }
        let now = Date().timeIntervalSince1970
        if now - self.defaults.double(forKey: "chitgram_update_offered_at") < self.remindInterval {
            return
        }
        self.defaults.set(now, forKey: "chitgram_update_offered_at")
        let alert = textAlertController(context: context, title: ChitgramStrings.format(591, latest), text: ChitgramStrings.get(592), actions: [
            TextAlertAction(type: .genericAction, title: ChitgramStrings.get(594), action: {}),
            TextAlertAction(type: .defaultAction, title: ChitgramStrings.get(593), action: {
                self.openUpdate(context: context)
            })
        ])
        context.sharedContext.mainWindow?.present(alert, on: .root)
    }
}

/// A full-screen notice: title, text and one button (maintenance, required update).
final class ChitgramNoticeController: ViewController {
    private let theme: PresentationTheme
    private let titleText: String
    private let text: String
    private var buttonTitle: String
    private let action: (ChitgramNoticeController) -> Void
    private var contentView: ChitgramNoticeView?

    init(theme: PresentationTheme, title: String, text: String, buttonTitle: String, action: @escaping (ChitgramNoticeController) -> Void) {
        self.theme = theme
        self.titleText = title
        self.text = text
        self.buttonTitle = buttonTitle
        self.action = action
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = theme.rootController.statusBarStyle.style
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setButtonTitle(_ title: String) {
        self.buttonTitle = title
        self.contentView?.setButtonTitle(title)
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.theme.list.plainBackgroundColor
        let contentView = ChitgramNoticeView(theme: self.theme, title: self.titleText, text: self.text, buttonTitle: self.buttonTitle, action: { [weak self] in
            guard let self else {
                return
            }
            self.action(self)
        })
        self.displayNode.view.addSubview(contentView)
        self.contentView = contentView
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.contentView?.frame = CGRect(origin: CGPoint(), size: layout.size)
    }
}

private final class ChitgramNoticeView: UIView {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let textLabel = UILabel()
    private let button = UIButton(type: .system)
    private let action: () -> Void

    init(theme: PresentationTheme, title: String, text: String, buttonTitle: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: CGRect())

        self.iconView.image = UIImage(systemName: "wrench.and.screwdriver.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 52.0, weight: .regular))?.withRenderingMode(.alwaysTemplate)
        self.iconView.tintColor = theme.list.itemAccentColor
        self.iconView.contentMode = .center
        self.addSubview(self.iconView)

        self.titleLabel.text = title
        self.titleLabel.font = UIFont.systemFont(ofSize: 22.0, weight: .bold)
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.titleLabel.textAlignment = .center
        self.titleLabel.numberOfLines = 0
        self.addSubview(self.titleLabel)

        self.textLabel.text = text
        self.textLabel.font = UIFont.systemFont(ofSize: 16.0)
        self.textLabel.textColor = theme.list.itemSecondaryTextColor
        self.textLabel.textAlignment = .center
        self.textLabel.numberOfLines = 0
        self.addSubview(self.textLabel)

        self.button.setTitle(buttonTitle, for: .normal)
        self.button.titleLabel?.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        self.button.setTitleColor(theme.list.itemCheckColors.foregroundColor, for: .normal)
        self.button.backgroundColor = theme.list.itemCheckColors.fillColor
        self.button.layer.cornerRadius = 12.0
        self.button.addTarget(self, action: #selector(self.buttonPressed), for: .touchUpInside)
        self.addSubview(self.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setButtonTitle(_ title: String) {
        self.button.setTitle(title, for: .normal)
    }

    @objc private func buttonPressed() {
        self.action()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        let sideInset: CGFloat = 32.0
        let width = size.width - sideInset * 2.0
        let titleSize = self.titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let textSize = self.textLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let total = 72.0 + 20.0 + titleSize.height + 12.0 + textSize.height + 32.0 + 50.0
        var y = max(40.0, (size.height - total) / 2.0)
        self.iconView.frame = CGRect(x: 0.0, y: y, width: size.width, height: 72.0)
        y += 72.0 + 20.0
        self.titleLabel.frame = CGRect(x: sideInset, y: y, width: width, height: titleSize.height)
        y += titleSize.height + 12.0
        self.textLabel.frame = CGRect(x: sideInset, y: y, width: width, height: textSize.height)
        y += textSize.height + 32.0
        self.button.frame = CGRect(x: sideInset, y: y, width: width, height: 50.0)
    }
}
