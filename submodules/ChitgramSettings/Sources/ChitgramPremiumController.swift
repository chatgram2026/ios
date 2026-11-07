import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramStringFormatting
import ItemListUI
import PresentationDataUtils
import AccountContext
import AppBundle
import LocalizedPeerData
import AsyncDisplayKit
import ComponentFlow
import PremiumStarComponent
import ConfettiEffect
import UndoUI
import ChitgramCore
import EntityKeyboard
import ChitgramEngine

/// The member's own emoji after their name (Android `BadgePicker`): Telegram's emoji status picker, whose choice is
/// written to the badge instead of the account's Telegram status.
private func chitgramOpenBadgePicker(context: AccountContext, sourceView: UIView, present: @escaping (ViewController) -> Void, showResult: @escaping (String) -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let current = ChitgramBadgeService.myEmoji(context: context)
    let save: (Int64) -> Void = { emoji in
        ChitgramBadgeService.setMyEmoji(context: context, emoji: emoji, completion: { error in
            if let error {
                showResult(ChitgramStrings.format(685, error))
            } else {
                showResult(ChitgramStrings.get(684))
            }
        })
    }
    let choose: () -> Void = {
        var selectedItems = Set<AnyHashable>()
        if current != 0 {
            selectedItems.insert(EngineMedia.Id(namespace: Namespaces.Media.CloudFile, id: current))
        }
        let emojiContent = EmojiPagerContentComponent.emojiInputData(
            context: context,
            animationCache: context.animationCache,
            animationRenderer: context.animationRenderer,
            isStandalone: false,
            subject: .status,
            hasTrending: false,
            topReactionItems: [],
            areUnicodeEmojiEnabled: false,
            areCustomEmojiEnabled: true,
            chatPeerId: context.account.peerId,
            selectedItems: selectedItems
        )
        |> map { content -> AnyObject in
            return content
        }
        let controller = context.sharedContext.makeEmojiStatusSelectionController(context: context, mode: .customStatusSelection(completion: { file, _ in
            if let file {
                save(file.fileId.id)
            }
        }), sourceView: sourceView, emojiContent: emojiContent, currentSelection: current != 0 ? current : nil, color: nil, destinationItemView: {
            return nil
        })
        present(controller)
    }
    if current == 0 {
        choose()
        return
    }
    let actionSheet = ActionSheetController(presentationData: presentationData)
    actionSheet.setItemGroups([
        ActionSheetItemGroup(items: [
            ActionSheetTextItem(title: ChitgramStrings.get(678), parseMarkdown: false),
            ActionSheetButtonItem(title: ChitgramStrings.get(682), color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                choose()
            }),
            ActionSheetButtonItem(title: ChitgramStrings.get(683), color: .destructive, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                save(0)
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

private func chitgramPlanTitle(_ plan: ChitgramPremium.Plan) -> String {
    if plan.months == 1 {
        return ChitgramStrings.get(431)
    } else if plan.months == 12 {
        return ChitgramStrings.get(432)
    } else if plan.months % 12 == 0 {
        return ChitgramStrings.format(551, plan.months / 12)
    } else {
        return ChitgramStrings.format(550, plan.months)
    }
}

/// Chitgram Premium's colours (Android `PremiumColors`): the brand blue running into violet, and the gold of Stars.
private enum ChitgramPremiumColors {
    static let blue = UIColor(rgb: 0x2F80FF)
    static let indigo = UIColor(rgb: 0x5B5BF5)
    static let violet = UIColor(rgb: 0x9B4DFF)
    static let gold = UIColor(rgb: 0xFFB300)
    static let goldDeep = UIColor(rgb: 0xF57C00)
    static let green = UIColor(rgb: 0x2EAF5A)
    static let hero: [UIColor] = [blue, indigo, violet]
}

/// Telegram's Premium gradient, which the perk icons run along from the first to the last.
private let chitgramPerkGradient: [UIColor] = [UIColor(rgb: 0x55A5FF), UIColor(rgb: 0x7E7BFF), UIColor(rgb: 0xA767FF), UIColor(rgb: 0xDB5C9D), UIColor(rgb: 0xF38926)]

private func chitgramGradientColor(at t: CGFloat) -> UIColor {
    let position = max(0.0, min(1.0, t)) * CGFloat(chitgramPerkGradient.count - 1)
    let index = min(Int(position), chitgramPerkGradient.count - 2)
    return chitgramPerkGradient[index].mixedWith(chitgramPerkGradient[index + 1], alpha: position - CGFloat(index))
}

private func chitgramPerkColors(_ index: Int, _ count: Int) -> [UIColor] {
    let t: CGFloat = count <= 1 ? 0.0 : CGFloat(index) / CGFloat(count - 1)
    return [chitgramGradientColor(at: t), chitgramGradientColor(at: t + 0.12)]
}

private func chitgramFormatStars(_ value: Int64) -> String {
    let digits = String(abs(value))
    var result = value < 0 ? "-" : ""
    for (index, digit) in digits.enumerated() {
        if index > 0 && (digits.count - index) % 3 == 0 {
            result.append(" ")
        }
        result.append(digit)
    }
    return result
}

private func chitgramFormatDate(_ timestamp: Int32) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "dd.MM.yyyy"
    return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
}

private func chitgramLabel(_ text: String?, font: UIFont, color: UIColor, alignment: NSTextAlignment = .natural, lines: Int = 0) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = font
    label.textColor = color
    label.textAlignment = alignment
    label.numberOfLines = lines
    return label
}

private func chitgramPin(_ view: UIView, to parent: UIView, top: CGFloat = 0.0, left: CGFloat = 0.0, bottom: CGFloat = 0.0, right: CGFloat = 0.0) {
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: parent.topAnchor, constant: top),
        view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: left),
        view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -bottom),
        view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -right)
    ])
}

private func chitgramFix(_ view: UIView, width: CGFloat? = nil, height: CGFloat? = nil) {
    view.translatesAutoresizingMaskIntoConstraints = false
    if let width {
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
    if let height {
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
    }
}

private func chitgramColumn(spacing: CGFloat = 0.0) -> UIStackView {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = spacing
    return stack
}

private func chitgramRow(spacing: CGFloat = 0.0) -> UIStackView {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = spacing
    stack.isUserInteractionEnabled = false
    return stack
}

private func chitgramCentered(_ view: UIView) -> UIView {
    let container = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: container.topAnchor),
        view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        view.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
        view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor)
    ])
    return container
}

private final class ChitgramGradientView: UIView {
    override class var layerClass: AnyClass {
        return CAGradientLayer.self
    }

    init(colors: [UIColor], start: CGPoint = CGPoint(), end: CGPoint = CGPoint(x: 1.0, y: 1.0)) {
        super.init(frame: CGRect())
        if let gradient = self.layer as? CAGradientLayer {
            gradient.colors = colors.map { $0.cgColor }
            gradient.startPoint = start
            gradient.endPoint = end
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A rounded gradient tile with a white icon, in the list and, larger, in the perk sheet (Android `iconTile`). The
/// icon is Android's own drawable (`Chitgram/Perk/…`), scaled down to fit the icon box but never up, as Android's
/// `CENTER_INSIDE` does.
private func chitgramIconTile(icon: String, colors: [UIColor], size: CGFloat, iconSize: CGFloat) -> UIView {
    let tile = ChitgramGradientView(colors: colors)
    tile.layer.cornerRadius = size * 0.27
    tile.clipsToBounds = true
    let image = UIImage(bundleImageName: icon)?.withRenderingMode(.alwaysTemplate)
    let imageView = UIImageView(image: image)
    imageView.tintColor = .white
    if let image, image.size.width > iconSize || image.size.height > iconSize {
        imageView.contentMode = .scaleAspectFit
    } else {
        imageView.contentMode = .center
    }
    imageView.translatesAutoresizingMaskIntoConstraints = false
    tile.addSubview(imageView)
    NSLayoutConstraint.activate([
        imageView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
        imageView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        imageView.widthAnchor.constraint(equalToConstant: iconSize),
        imageView.heightAnchor.constraint(equalToConstant: iconSize)
    ])
    chitgramFix(tile, width: size, height: size)
    return tile
}

/// The big call to action: a rounded gradient with a soft band of light sweeping across it (Android `ShineButton`).
private final class ChitgramShineButton: UIControl {
    private let gradientView: ChitgramGradientView
    private let shineLayer = CAGradientLayer()
    private let titleLabel = UILabel()
    private let action: () -> Void

    var title: String? {
        didSet {
            self.titleLabel.text = self.title
        }
    }

    override var isEnabled: Bool {
        didSet {
            self.alpha = self.isEnabled ? 1.0 : 0.55
            self.restartShine()
        }
    }

    override var isHighlighted: Bool {
        didSet {
            self.gradientView.alpha = self.isHighlighted ? 0.8 : 1.0
        }
    }

    init(colors: [UIColor], action: @escaping () -> Void) {
        self.gradientView = ChitgramGradientView(colors: colors)
        self.action = action
        super.init(frame: CGRect())

        self.layer.cornerRadius = 12.0
        self.clipsToBounds = true

        self.gradientView.isUserInteractionEnabled = false
        self.addSubview(self.gradientView)

        self.shineLayer.colors = [UIColor(white: 1.0, alpha: 0.0).cgColor, UIColor(white: 1.0, alpha: 0.33).cgColor, UIColor(white: 1.0, alpha: 0.0).cgColor]
        self.shineLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
        self.shineLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        self.layer.addSublayer(self.shineLayer)

        self.titleLabel.font = Font.semibold(15.5)
        self.titleLabel.textColor = .white
        self.titleLabel.textAlignment = .center
        self.titleLabel.isUserInteractionEnabled = false
        self.addSubview(self.titleLabel)

        self.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func pressed() {
        self.action()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        self.restartShine()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        self.gradientView.frame = CGRect(origin: CGPoint(), size: size)
        self.titleLabel.frame = CGRect(x: 16.0, y: 0.0, width: max(0.0, size.width - 32.0), height: size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.shineLayer.frame = CGRect(x: -size.width, y: 0.0, width: size.width * 0.45, height: size.height)
        CATransaction.commit()
        self.restartShine()
    }

    private func restartShine() {
        self.shineLayer.removeAllAnimations()
        let width = self.bounds.width
        guard self.window != nil, self.isEnabled, width > 0.0 else {
            return
        }
        // The band crosses during the first 60 % of each cycle, then rests.
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -width * 0.25 as NSNumber
        move.toValue = width * 1.25 as NSNumber
        move.duration = 1.44
        move.timingFunction = CAMediaTimingFunction(name: .linear)
        let group = CAAnimationGroup()
        group.animations = [move]
        group.duration = 2.4
        group.repeatCount = .infinity
        self.shineLayer.add(group, forKey: "shine")
    }
}

/// A plan's radio dot: an outlined circle that fills with the brand gradient when chosen (Android `RadioDot`).
private final class ChitgramRadioDot: UIView {
    private let checked: Bool
    private let idleColor: UIColor

    init(checked: Bool, idleColor: UIColor) {
        self.checked = checked
        self.idleColor = idleColor
        super.init(frame: CGRect())
        self.backgroundColor = .clear
        self.isOpaque = false
        chitgramFix(self, width: 24.0, height: 24.0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        let center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
        let radius = min(self.bounds.width, self.bounds.height) / 2.0 - 1.5
        if self.checked {
            context.saveGState()
            let outer = radius + 1.0
            context.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2.0, height: outer * 2.0))
            context.clip()
            let colors = [ChitgramPremiumColors.blue.cgColor, ChitgramPremiumColors.violet.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) {
                context.drawLinearGradient(gradient, start: CGPoint(), end: CGPoint(x: self.bounds.width, y: self.bounds.height), options: [])
            }
            context.restoreGState()
            context.setStrokeColor(UIColor.white.cgColor)
            context.setLineWidth(2.2)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: center.x - radius * 0.42, y: center.y + radius * 0.02))
            context.addLine(to: CGPoint(x: center.x - radius * 0.1, y: center.y + radius * 0.34))
            context.addLine(to: CGPoint(x: center.x + radius * 0.46, y: center.y - radius * 0.3))
            context.strokePath()
        } else {
            context.setStrokeColor(self.idleColor.cgColor)
            context.setLineWidth(2.0)
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2.0, height: radius * 2.0))
        }
    }
}

/// A row that highlights while pressed.
private final class ChitgramPressableRow: UIControl {
    private let highlightColor: UIColor
    private let action: () -> Void

    override var isHighlighted: Bool {
        didSet {
            self.backgroundColor = self.isHighlighted ? self.highlightColor : .clear
        }
    }

    init(highlightColor: UIColor, action: @escaping () -> Void) {
        self.highlightColor = highlightColor
        self.action = action
        super.init(frame: CGRect())
        self.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func pressed() {
        self.action()
    }
}

/// Telegram's 3D star over its burst of small stars, in the given colours.
private final class ChitgramStarHeaderView: UIView {
    private let star = ComponentView<Empty>()
    private let theme: PresentationTheme
    private let colors: [UIColor]
    private let particleColor: UIColor
    private var currentSize = CGSize()

    init(theme: PresentationTheme, colors: [UIColor], particleColor: UIColor) {
        self.theme = theme
        self.colors = colors
        self.particleColor = particleColor
        super.init(frame: CGRect())
        self.isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        if size == self.currentSize || size.width <= 0.0 {
            return
        }
        self.currentSize = size
        let _ = self.star.update(
            transition: .immediate,
            component: AnyComponent(PremiumStarComponent(
                theme: self.theme,
                isIntro: true,
                isVisible: true,
                hasIdleAnimations: true,
                colors: self.colors,
                particleColor: self.particleColor,
                backgroundColor: nil
            )),
            environment: {},
            containerSize: size
        )
        if let view = self.star.view {
            if view.superview == nil {
                self.addSubview(view)
            }
            view.frame = CGRect(origin: CGPoint(), size: size)
        }
    }
}

/// A sheet rising from the bottom over the page (Android `PremiumSheets`).
private final class ChitgramPremiumSheetView: UIView {
    private let dimView = UIControl()
    private let panel = UIView()
    private let content: UIView
    private let bottomInset: CGFloat

    init(backgroundColor: UIColor, content: UIView, bottomInset: CGFloat) {
        self.content = content
        self.bottomInset = bottomInset
        super.init(frame: CGRect())

        self.dimView.backgroundColor = UIColor(white: 0.0, alpha: 0.4)
        self.dimView.addTarget(self, action: #selector(self.dimPressed), for: .touchUpInside)
        self.addSubview(self.dimView)

        self.panel.backgroundColor = backgroundColor
        self.panel.layer.cornerRadius = 16.0
        self.panel.clipsToBounds = true
        self.addSubview(self.panel)
        self.panel.addSubview(content)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func dimPressed() {
        self.dismiss()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.dimView.frame = self.bounds
        let width = min(self.bounds.width, 500.0)
        let fitting = self.content.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let contentHeight = ceil(fitting.height)
        let panelHeight = contentHeight + self.bottomInset
        self.panel.bounds = CGRect(x: 0.0, y: 0.0, width: width, height: panelHeight + 20.0)
        self.panel.center = CGPoint(x: self.bounds.midX, y: self.bounds.height - panelHeight + (panelHeight + 20.0) / 2.0)
        self.content.frame = CGRect(x: 0.0, y: 0.0, width: width, height: contentHeight)
    }

    func animateIn() {
        self.layoutIfNeeded()
        self.dimView.alpha = 0.0
        self.panel.transform = CGAffineTransform(translationX: 0.0, y: self.panel.bounds.height)
        UIView.animate(withDuration: 0.32, delay: 0.0, options: [.curveEaseOut], animations: {
            self.dimView.alpha = 1.0
            self.panel.transform = .identity
        })
    }

    func dismiss(completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: 0.25, delay: 0.0, options: [.curveEaseIn], animations: {
            self.dimView.alpha = 0.0
            self.panel.transform = CGAffineTransform(translationX: 0.0, y: self.panel.bounds.height)
        }, completion: { _ in
            self.removeFromSuperview()
            completion?()
        })
    }
}

private struct ChitgramPremiumPerk {
    /// Android's drawable for the perk, in `Chitgram/Perk`.
    let icon: String
    let colors: [UIColor]
    let title: String
    let text: String
    let free: String
    let premium: String
    let open: (() -> Void)?
}

/// Settings ▸ Chitgram ▸ Chitgram Premium (Android `ChitgramPremiumScreen`): the turning star above the title, the plans
/// as a radio list in one card with the Stars balance, the perks along the Premium gradient, how it works, and a shining
/// button pinned to the bottom with the chosen plan's price. Paying opens a sheet with the price against the balance;
/// a successful payment ends in confetti and a welcome.
private final class ChitgramPremiumScreen: ViewController, UIScrollViewDelegate {
    private let context: AccountContext
    private let presentationData: PresentationData
    private var accountPeerId: EnginePeer.Id {
        return self.context.account.peerId
    }

    private let scrollView = UIScrollView()
    private let contentStack = chitgramColumn()
    private let bottomPanel = UIView()
    private let bottomCaption = UILabel()
    private var buyButton: ChitgramShineButton?
    private var starHeader: ChitgramStarHeaderView?
    private var statusLabel: UILabel?
    private var statusPill: UIView?
    private var balanceLabel: UILabel?
    private var plansStack: UIStackView?
    private var badgeCard: UIView?
    private var currentPlans: [ChitgramPremium.Plan] = []
    private var selectedPlan: ChitgramPremium.Plan?
    private var balance: Int64?
    private var busy = false
    private var showsTitle = false
    private var navigationHeight: CGFloat = 0.0
    private var bottomInset: CGFloat = 0.0
    private var openSheet: ChitgramPremiumSheetView?

    private var balanceDisposable: Disposable?
    private var preferencesDisposable: Disposable?

    private var theme: PresentationTheme {
        return self.presentationData.theme
    }

    private var primaryTextColor: UIColor {
        return self.theme.list.itemPrimaryTextColor
    }

    private var secondaryTextColor: UIColor {
        return self.theme.list.itemSecondaryTextColor
    }

    private var accentColor: UIColor {
        return self.theme.list.itemAccentColor
    }

    private var highlightColor: UIColor {
        return self.theme.list.itemHighlightedBackgroundColor
    }

    init(context: AccountContext) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }

        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))

        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.balanceDisposable?.dispose()
        self.preferencesDisposable?.dispose()
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.theme.list.blocksBackgroundColor
        self.displayNodeDidLoad()

        self.scrollView.delegate = self
        self.scrollView.showsVerticalScrollIndicator = false
        self.scrollView.alwaysBounceVertical = true
        self.scrollView.contentInsetAdjustmentBehavior = .never
        self.displayNode.view.insertSubview(self.scrollView, at: 0)

        self.contentStack.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.addSubview(self.contentStack)
        NSLayoutConstraint.activate([
            self.contentStack.topAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.topAnchor),
            self.contentStack.leadingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.leadingAnchor),
            self.contentStack.trailingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.trailingAnchor),
            self.contentStack.bottomAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.bottomAnchor),
            self.contentStack.widthAnchor.constraint(equalTo: self.scrollView.frameLayoutGuide.widthAnchor)
        ])

        self.contentStack.addArrangedSubview(self.makeHeader())
        let body = chitgramColumn(spacing: 16.0)
        body.isLayoutMarginsRelativeArrangement = true
        body.layoutMargins = UIEdgeInsets(top: 20.0, left: 16.0, bottom: 16.0, right: 16.0)
        let badgeCard = self.makeBadgeCard()
        self.badgeCard = badgeCard
        let cards: [UIView] = [
            self.makePlansCard(),
            badgeCard,
            self.makePerksCard(),
            self.makeHowCard()
        ]
        for card in cards {
            body.addArrangedSubview(card)
        }
        let footer = chitgramLabel(ChitgramStrings.get(436), font: Font.regular(12.5), color: self.secondaryTextColor, alignment: .center)
        let footerBox = UIView()
        footerBox.addSubview(footer)
        chitgramPin(footer, to: footerBox, top: 0.0, left: 18.0, bottom: 0.0, right: 18.0)
        body.addArrangedSubview(footerBox)
        self.contentStack.addArrangedSubview(body)

        self.bottomPanel.backgroundColor = self.theme.list.itemBlocksBackgroundColor
        self.bottomPanel.layer.shadowColor = UIColor.black.cgColor
        self.bottomPanel.layer.shadowOpacity = 0.12
        self.bottomPanel.layer.shadowRadius = 6.0
        self.bottomPanel.layer.shadowOffset = CGSize(width: 0.0, height: -2.0)
        let buyButton = ChitgramShineButton(colors: ChitgramPremiumColors.hero, action: { [weak self] in
            self?.buyPressed()
        })
        self.buyButton = buyButton
        self.bottomPanel.addSubview(buyButton)
        self.bottomCaption.text = ChitgramStrings.get(653)
        self.bottomCaption.font = Font.regular(12.5)
        self.bottomCaption.textColor = self.secondaryTextColor
        self.bottomCaption.textAlignment = .center
        self.bottomPanel.addSubview(self.bottomCaption)
        self.displayNode.view.insertSubview(self.bottomPanel, aboveSubview: self.scrollView)

        self.updateStatus()
        self.fillPlans()
        self.updateBalance()
        self.animateIn(body)

        if let starsContext = self.context.starsContext {
            starsContext.load(force: false)
            self.balanceDisposable = (starsContext.state
            |> deliverOnMainQueue).startStrict(next: { [weak self] state in
                guard let self else {
                    return
                }
                self.balance = state?.balance.value
                self.updateBalance()
            })
        }
        // Prices and the status are kept in the store, so a change there is what to show.
        self.preferencesDisposable = (ChitgramPreferences.shared.changes
        |> deliverOnMainQueue).startStrict(next: { [weak self] _ in
            guard let self else {
                return
            }
            self.updateStatus()
            if ChitgramPremium.plans() != self.currentPlans {
                self.fillPlans()
            }
        })

        // The prices may have changed since the last look, and the status is checked each time the page opens.
        let _ = ChitgramPremium.refreshPlans(context: self.context).startStandalone()
        let _ = ChitgramPremium.refresh(context: self.context).startStandalone()
    }

    private func animateIn(_ column: UIStackView) {
        for (index, child) in column.arrangedSubviews.enumerated() {
            child.alpha = 0.0
            child.transform = CGAffineTransform(translationX: 0.0, y: 28.0)
            UIView.animate(withDuration: 0.38, delay: 0.12 + 0.07 * Double(index), options: [.curveEaseOut], animations: {
                child.alpha = 1.0
                child.transform = .identity
            })
        }
    }

    // MARK: Header

    private func makeHeader() -> UIView {
        let header = chitgramColumn()
        header.alignment = .center

        let starHeader = ChitgramStarHeaderView(theme: self.theme, colors: [ChitgramPremiumColors.blue, ChitgramPremiumColors.indigo, ChitgramPremiumColors.violet, ChitgramPremiumColors.violet], particleColor: ChitgramPremiumColors.violet)
        self.starHeader = starHeader
        chitgramFix(starHeader, height: 210.0)
        header.addArrangedSubview(starHeader)
        starHeader.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

        header.addArrangedSubview(chitgramLabel(ChitgramStrings.get(427), font: Font.bold(24.0), color: self.primaryTextColor, alignment: .center))
        let subtitle = chitgramLabel(ChitgramStrings.get(629), font: Font.regular(15.0), color: self.secondaryTextColor, alignment: .center)
        header.setCustomSpacing(8.0, after: header.arrangedSubviews[1])
        header.addArrangedSubview(subtitle)
        subtitle.widthAnchor.constraint(lessThanOrEqualTo: header.widthAnchor, constant: -64.0).isActive = true
        header.setCustomSpacing(16.0, after: subtitle)

        let statusLabel = chitgramLabel(nil, font: Font.semibold(14.0), color: self.accentColor, alignment: .center)
        self.statusLabel = statusLabel
        let statusPill = UIView()
        statusPill.layer.cornerRadius = 16.0
        statusPill.clipsToBounds = true
        statusPill.addSubview(statusLabel)
        chitgramPin(statusLabel, to: statusPill, top: 7.0, left: 14.0, bottom: 7.0, right: 16.0)
        self.statusPill = statusPill
        header.addArrangedSubview(statusPill)
        statusPill.widthAnchor.constraint(lessThanOrEqualTo: header.widthAnchor, constant: -32.0).isActive = true
        return header
    }

    private func updateStatus() {
        let isActive = ChitgramPremium.isActive(accountPeerId: self.accountPeerId)
        self.badgeCard?.isHidden = !isActive
        let tint = isActive ? ChitgramPremiumColors.green : self.accentColor
        self.statusLabel?.text = isActive ? "\u{2713}  " + ChitgramStrings.format(428, chitgramFormatDate(ChitgramPremium.until(accountPeerId: self.accountPeerId))) : ChitgramStrings.get(429)
        self.statusLabel?.textColor = tint
        self.statusPill?.backgroundColor = tint.withAlphaComponent(0.11)
        self.updateBuyButton()
    }

    // MARK: Cards

    private func makeCard() -> UIStackView {
        let card = chitgramColumn()
        card.isLayoutMarginsRelativeArrangement = false
        let background = UIView()
        background.backgroundColor = self.theme.list.itemBlocksBackgroundColor
        background.layer.cornerRadius = 16.0
        background.clipsToBounds = true
        card.insertSubview(background, at: 0)
        chitgramPin(background, to: card)
        card.layer.cornerRadius = 16.0
        card.clipsToBounds = true
        return card
    }

    private func makeCardHeader(_ title: String) -> UIView {
        let box = UIView()
        let label = chitgramLabel(title, font: Font.semibold(15.0), color: self.accentColor)
        box.addSubview(label)
        chitgramPin(label, to: box, top: 14.0, left: 16.0, bottom: 6.0, right: 16.0)
        return box
    }

    private func makeDivider(inset: CGFloat) -> UIView {
        let box = UIView()
        let line = UIView()
        line.backgroundColor = self.theme.list.itemBlocksSeparatorColor
        box.addSubview(line)
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: box.topAnchor),
            line.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
            line.trailingAnchor.constraint(equalTo: box.trailingAnchor)
        ])
        chitgramFix(box, height: UIScreenPixel)
        return box
    }

    private func makeArrow() -> UIView {
        // Android's `msg_arrowright`, at its own 24 pt.
        let arrow = UIImageView(image: UIImage(bundleImageName: "Chitgram/Perk/Arrow")?.withRenderingMode(.alwaysTemplate))
        arrow.tintColor = self.theme.list.disclosureArrowColor
        arrow.contentMode = .center
        chitgramFix(arrow, width: 24.0, height: 24.0)
        return arrow
    }

    private func makeRow(content: UIView, top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat, action: @escaping () -> Void) -> UIView {
        let row = ChitgramPressableRow(highlightColor: self.highlightColor, action: action)
        content.isUserInteractionEnabled = false
        row.addSubview(content)
        chitgramPin(content, to: row, top: top, left: left, bottom: bottom, right: right)
        return row
    }

    // MARK: Plans

    private func makePlansCard() -> UIView {
        let card = self.makeCard()
        let plansStack = chitgramColumn()
        self.plansStack = plansStack
        card.addArrangedSubview(plansStack)
        card.addArrangedSubview(self.makeDivider(inset: 16.0))

        let balanceLabel = chitgramLabel(nil, font: Font.regular(14.0), color: self.secondaryTextColor, lines: 1)
        self.balanceLabel = balanceLabel
        let topUp = UIButton(type: .system)
        topUp.setTitle(ChitgramStrings.get(632), for: .normal)
        topUp.setTitleColor(self.accentColor, for: .normal)
        topUp.titleLabel?.font = Font.semibold(14.0)
        topUp.addTarget(self, action: #selector(self.topUpPressed), for: .touchUpInside)
        topUp.setContentCompressionResistancePriority(.required, for: .horizontal)
        topUp.setContentHuggingPriority(.required, for: .horizontal)

        let balanceRow = UIStackView()
        balanceRow.axis = .horizontal
        balanceRow.alignment = .center
        balanceRow.spacing = 10.0
        balanceRow.addArrangedSubview(balanceLabel)
        balanceRow.addArrangedSubview(topUp)
        let balanceBox = UIView()
        balanceBox.addSubview(balanceRow)
        chitgramPin(balanceRow, to: balanceBox, top: 6.0, left: 16.0, bottom: 6.0, right: 18.0)
        card.addArrangedSubview(balanceBox)
        return card
    }

    @objc private func topUpPressed() {
        self.push(self.context.sharedContext.makeStarsIntroScreen(context: self.context))
    }

    /// One row per tariff from the channel pin, the best value chosen first, the "N months free" worked out.
    private func fillPlans() {
        guard let plansStack = self.plansStack else {
            return
        }
        for view in plansStack.arrangedSubviews {
            plansStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let plans = ChitgramPremium.plans()
        self.currentPlans = plans
        if plans.isEmpty {
            self.updateBuyButton()
            return
        }
        let monthly = plans.first(where: { $0.months == 1 })?.stars
        if self.selectedPlan == nil || !plans.contains(where: { $0 == self.selectedPlan }) {
            self.selectedPlan = plans.max(by: { $0.months < $1.months })
        }
        for (index, plan) in plans.enumerated() {
            if index > 0 {
                plansStack.addArrangedSubview(self.makeDivider(inset: 58.0))
            }
            var badge: String?
            if let monthly, monthly > 0, plan.months > 1 {
                let free = (Int64(plan.months) * monthly - plan.stars) / monthly
                if free >= 1 {
                    badge = ChitgramStrings.format(552, Int(free))
                }
            }
            plansStack.addArrangedSubview(self.makePlanRow(plan: plan, badge: badge))
        }
        self.updateBuyButton()
    }

    private func makePlanRow(plan: ChitgramPremium.Plan, badge: String?) -> UIView {
        let isChosen = plan == self.selectedPlan
        let row = chitgramRow(spacing: 18.0)
        row.addArrangedSubview(ChitgramRadioDot(checked: isChosen, idleColor: self.theme.list.itemCheckColors.strokeColor))

        let texts = chitgramColumn(spacing: 2.0)
        let titleLine = chitgramRow(spacing: 8.0)
        titleLine.addArrangedSubview(chitgramLabel(chitgramPlanTitle(plan), font: Font.semibold(16.0), color: self.primaryTextColor, lines: 1))
        if let badge {
            let pill = ChitgramGradientView(colors: [ChitgramPremiumColors.blue, ChitgramPremiumColors.violet], start: CGPoint(x: 0.0, y: 0.5), end: CGPoint(x: 1.0, y: 0.5))
            pill.layer.cornerRadius = 5.0
            pill.clipsToBounds = true
            let label = chitgramLabel(badge, font: Font.semibold(11.5), color: .white, lines: 1)
            pill.addSubview(label)
            chitgramPin(label, to: pill, top: 1.0, left: 6.0, bottom: 2.0, right: 6.0)
            titleLine.addArrangedSubview(pill)
        }
        let titleBox = UIView()
        titleBox.addSubview(titleLine)
        titleLine.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLine.topAnchor.constraint(equalTo: titleBox.topAnchor),
            titleLine.bottomAnchor.constraint(equalTo: titleBox.bottomAnchor),
            titleLine.leadingAnchor.constraint(equalTo: titleBox.leadingAnchor),
            titleLine.trailingAnchor.constraint(lessThanOrEqualTo: titleBox.trailingAnchor)
        ])
        texts.addArrangedSubview(titleBox)
        if plan.months > 1 {
            let perMonth = (plan.stars + Int64(plan.months) - 1) / Int64(plan.months)
            texts.addArrangedSubview(chitgramLabel(ChitgramStrings.format(631, chitgramFormatStars(perMonth)), font: Font.regular(14.0), color: self.secondaryTextColor, lines: 1))
        }
        row.addArrangedSubview(texts)
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let price = chitgramLabel("\(chitgramFormatStars(plan.stars)) \u{2B50}", font: isChosen ? Font.semibold(16.0) : Font.regular(16.0), color: isChosen ? self.primaryTextColor : self.secondaryTextColor, lines: 1)
        price.setContentCompressionResistancePriority(.required, for: .horizontal)
        price.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(price)

        return self.makeRow(content: row, top: 13.0, left: 16.0, bottom: 13.0, right: 16.0, action: { [weak self] in
            guard let self, self.selectedPlan != plan else {
                return
            }
            self.selectedPlan = plan
            self.fillPlans()
        })
    }

    private func updateBalance() {
        if let balance = self.balance {
            self.balanceLabel?.text = ChitgramStrings.format(434, chitgramFormatStars(balance))
        } else {
            self.balanceLabel?.text = ChitgramStrings.get(444)
        }
    }

    private func updateBuyButton() {
        guard let buyButton = self.buyButton, let plan = self.selectedPlan else {
            return
        }
        buyButton.isEnabled = !self.busy
        if self.busy {
            buyButton.title = ChitgramStrings.get(658)
        } else if ChitgramPremium.isActive(accountPeerId: self.accountPeerId) {
            buyButton.title = ChitgramStrings.format(652, chitgramFormatStars(plan.stars))
        } else {
            buyButton.title = ChitgramStrings.format(651, chitgramFormatStars(plan.stars))
        }
    }

    // MARK: The badge

    /// For members: the badge as others see it and the way to pick its emoji. Hidden without Premium.
    private func makeBadgeCard() -> UIView {
        let card = self.makeCard()
        card.addArrangedSubview(self.makeCardHeader(ChitgramStrings.get(678)))

        let row = chitgramRow(spacing: 14.0)
        let tile = UIImageView(image: UIImage(bundleImageName: "Chitgram/BadgeTile"))
        tile.layer.cornerRadius = 10.0
        tile.clipsToBounds = true
        chitgramFix(tile, width: 44.0, height: 44.0)
        row.addArrangedSubview(tile)
        let texts = chitgramColumn(spacing: 2.0)
        let nameLabel = chitgramLabel(nil, font: Font.semibold(15.5), color: self.primaryTextColor, lines: 1)
        texts.addArrangedSubview(nameLabel)
        let presentationData = self.presentationData
        let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.accountPeerId))
        |> deliverOnMainQueue).startStandalone(next: { [weak nameLabel] peer in
            nameLabel?.text = peer?.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        })
        texts.addArrangedSubview(chitgramLabel(ChitgramStrings.get(682), font: Font.regular(14.0), color: self.accentColor, lines: 1))
        row.addArrangedSubview(texts)
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(self.makeArrow())
        card.addArrangedSubview(self.makeRow(content: row, top: 10.0, left: 16.0, bottom: 12.0, right: 12.0, action: { [weak self] in
            self?.openBadgePicker()
        }))

        let noteBox = UIView()
        let note = chitgramLabel(ChitgramStrings.get(679), font: Font.regular(13.0), color: self.secondaryTextColor)
        noteBox.addSubview(note)
        chitgramPin(note, to: noteBox, top: 0.0, left: 16.0, bottom: 14.0, right: 16.0)
        card.addArrangedSubview(noteBox)
        return card
    }

    private func showToast(_ text: String) {
        self.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
    }

    private func openBadgePicker() {
        // Without Premium the buy button is right here on this page (Android: the same).
        guard ChitgramPremium.isActive(accountPeerId: self.accountPeerId) else {
            self.showToast(ChitgramStrings.get(687))
            return
        }
        chitgramOpenBadgePicker(context: self.context, sourceView: self.view, present: { [weak self] c in
            self?.present(c, in: .current)
        }, showResult: { [weak self] text in
            self?.showToast(text)
        })
    }

    // MARK: Perks

    private func perks() -> [ChitgramPremiumPerk] {
        let count = 6
        return [
            ChitgramPremiumPerk(icon: "Chitgram/Perk/Badge", colors: chitgramPerkColors(0, count), title: ChitgramStrings.get(678), text: ChitgramStrings.get(679), free: ChitgramStrings.get(680), premium: ChitgramStrings.get(681), open: { [weak self] in
                self?.openBadgePicker()
            }),
            // Chitgram (Novagram base): the auto messenger and keyword watch screens are not ported yet, so these two
            // perks show their sheet without an "open" button for now.
            ChitgramPremiumPerk(icon: "Chitgram/Perk/Clock", colors: chitgramPerkColors(1, count), title: ChitgramStrings.get(449), text: ChitgramStrings.get(634), free: ChitgramStrings.get(641), premium: ChitgramStrings.get(642), open: nil),
            ChitgramPremiumPerk(icon: "Chitgram/Perk/Notifications", colors: chitgramPerkColors(2, count), title: ChitgramStrings.get(568), text: ChitgramStrings.get(635), free: ChitgramStrings.format(643, ChitgramKeywords.freeWords), premium: ChitgramStrings.format(643, ChitgramKeywords.premiumWords), open: nil),
            ChitgramPremiumPerk(icon: "Chitgram/Perk/Accounts", colors: chitgramPerkColors(3, count), title: ChitgramStrings.get(598).replacingOccurrences(of: "%2$d", with: "\(ChitgramLimits.premiumAccounts)"), text: ChitgramStrings.get(636), free: ChitgramStrings.format(644, ChitgramLimits.freeAccounts), premium: ChitgramStrings.format(644, ChitgramLimits.premiumAccounts), open: nil),
            ChitgramPremiumPerk(icon: "Chitgram/Perk/Share", colors: chitgramPerkColors(4, count), title: ChitgramStrings.get(637), text: ChitgramStrings.get(638), free: ChitgramStrings.format(645, ChitgramLimits.freeShareBulk), premium: ChitgramStrings.format(645, ChitgramLimits.premiumShareBulk), open: nil),
            ChitgramPremiumPerk(icon: "Chitgram/Perk/Block", colors: chitgramPerkColors(5, count), title: ChitgramStrings.get(451), text: ChitgramStrings.get(452), free: ChitgramStrings.get(646), premium: ChitgramStrings.get(451), open: nil)
        ]
    }

    private func makePerksCard() -> UIView {
        let card = self.makeCard()
        card.addArrangedSubview(self.makeCardHeader(ChitgramStrings.get(633)))
        for (index, perk) in self.perks().enumerated() {
            if index > 0 {
                card.addArrangedSubview(self.makeDivider(inset: 62.0))
            }
            let row = chitgramRow(spacing: 16.0)
            row.addArrangedSubview(chitgramIconTile(icon: perk.icon, colors: perk.colors, size: 30.0, iconSize: 20.0))
            let texts = chitgramColumn(spacing: 2.0)
            texts.addArrangedSubview(chitgramLabel(perk.title, font: Font.semibold(15.5), color: self.primaryTextColor))
            texts.addArrangedSubview(chitgramLabel(perk.text, font: Font.regular(14.0), color: self.secondaryTextColor))
            row.addArrangedSubview(texts)
            texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(self.makeArrow())
            card.addArrangedSubview(self.makeRow(content: row, top: 11.0, left: 16.0, bottom: 11.0, right: 12.0, action: { [weak self] in
                self?.showPerk(perk)
            }))
        }
        return card
    }

    // MARK: How it works

    private func makeHowCard() -> UIView {
        let card = self.makeCard()
        card.addArrangedSubview(self.makeCardHeader(ChitgramStrings.get(647)))
        for (index, code) in [648, 649, 650].enumerated() {
            let step = chitgramRow(spacing: 18.0)
            let circle = ChitgramGradientView(colors: chitgramPerkColors(index, 3))
            circle.layer.cornerRadius = 13.0
            circle.clipsToBounds = true
            chitgramFix(circle, width: 26.0, height: 26.0)
            let number = chitgramLabel("\(index + 1)", font: Font.semibold(13.0), color: .white, alignment: .center, lines: 1)
            circle.addSubview(number)
            chitgramPin(number, to: circle)
            step.addArrangedSubview(circle)
            let text = chitgramLabel(ChitgramStrings.get(code), font: Font.regular(15.0), color: self.primaryTextColor)
            step.addArrangedSubview(text)
            let box = UIView()
            box.addSubview(step)
            chitgramPin(step, to: box, top: 8.0, left: 16.0, bottom: 8.0, right: 16.0)
            card.addArrangedSubview(box)
        }
        let spacer = UIView()
        chitgramFix(spacer, height: 6.0)
        card.addArrangedSubview(spacer)
        card.addArrangedSubview(self.makeDivider(inset: 16.0))
        // Android's restore line is text only; here it carries Android's `msg_retry` icon too, as every row of the page
        // has one (owner, 2026-11-07).
        let restoreIcon = UIImageView(image: UIImage(bundleImageName: "Chitgram/Perk/Restore")?.withRenderingMode(.alwaysTemplate))
        restoreIcon.tintColor = self.accentColor
        restoreIcon.contentMode = .center
        chitgramFix(restoreIcon, width: 24.0, height: 24.0)
        let restoreRow = chitgramRow(spacing: 8.0)
        restoreRow.addArrangedSubview(restoreIcon)
        restoreRow.addArrangedSubview(chitgramLabel(ChitgramStrings.get(435), font: Font.regular(15.5), color: self.accentColor, lines: 1))
        let restore = chitgramCentered(restoreRow)
        card.addArrangedSubview(self.makeRow(content: restore, top: 14.0, left: 16.0, bottom: 14.0, right: 16.0, action: { [weak self] in
            self?.restorePressed()
        }))
        return card
    }

    // MARK: Actions

    private func buyPressed() {
        guard !self.busy, let plan = self.selectedPlan else {
            return
        }
        self.showPay(plan: plan)
    }

    private func purchase(plan: ChitgramPremium.Plan) {
        self.busy = true
        self.updateBuyButton()
        let context = self.context
        let _ = (ChitgramPremium.buy(context: context, plan: plan)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] result in
            guard let self else {
                return
            }
            self.busy = false
            self.updateBuyButton()
            switch result {
            case let .activated(until):
                self.updateStatus()
                self.view.addSubview(ConfettiView(frame: self.view.bounds))
                self.showWelcome(until: until)
                // Confirm against the real history once Telegram has recorded the payment.
                let _ = (Signal<Int32?, NoError>.complete() |> delay(3.0, queue: Queue.mainQueue()) |> then(ChitgramPremium.refresh(context: context))).startStandalone()
            case .notEnoughStars:
                self.push(context.sharedContext.makeStarsIntroScreen(context: context))
            case let .failed(reason):
                self.showToast(reason.contains("REACTION") ? ChitgramStrings.get(441) : ChitgramStrings.format(440, reason))
            }
        })
    }

    private func restorePressed() {
        guard !self.busy else {
            return
        }
        self.busy = true
        self.statusLabel?.text = ChitgramStrings.get(444)
        let _ = (ChitgramPremium.refresh(context: self.context)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] until in
            guard let self else {
                return
            }
            self.busy = false
            self.updateStatus()
            if let until {
                if until > Int32(Date().timeIntervalSince1970) {
                    self.showToast(ChitgramStrings.format(439, chitgramFormatDate(until)))
                } else {
                    self.showToast(ChitgramStrings.get(442))
                }
            } else {
                self.showToast(ChitgramStrings.format(440, "NETWORK"))
            }
        })
    }

    // MARK: Sheets

    private func present(sheetContent: UIStackView) {
        self.openSheet?.removeFromSuperview()
        sheetContent.isLayoutMarginsRelativeArrangement = true
        sheetContent.layoutMargins = UIEdgeInsets(top: 20.0, left: 22.0, bottom: 14.0, right: 22.0)
        let sheet = ChitgramPremiumSheetView(backgroundColor: self.theme.list.itemBlocksBackgroundColor, content: sheetContent, bottomInset: self.bottomInset)
        sheet.frame = self.view.bounds
        self.view.addSubview(sheet)
        self.openSheet = sheet
        sheet.animateIn()
    }

    private func makeTextButton(_ title: String, action: @escaping () -> Void) -> UIView {
        let label = chitgramLabel(title, font: Font.semibold(15.0), color: self.accentColor, alignment: .center, lines: 1)
        return self.makeRow(content: label, top: 12.0, left: 12.0, bottom: 12.0, right: 12.0, action: action)
    }

    /// A perk with what Premium changes: free next to Premium, so the difference is what the eye lands on.
    private func showPerk(_ perk: ChitgramPremiumPerk) {
        let isActive = ChitgramPremium.isActive(accountPeerId: self.accountPeerId)
        let column = chitgramColumn()
        column.addArrangedSubview(chitgramCentered(chitgramIconTile(icon: perk.icon, colors: perk.colors, size: 76.0, iconSize: 40.0)))
        let title = chitgramLabel(perk.title, font: Font.bold(22.0), color: self.primaryTextColor, alignment: .center)
        column.setCustomSpacing(16.0, after: column.arrangedSubviews[0])
        column.addArrangedSubview(title)
        column.setCustomSpacing(8.0, after: title)
        let text = chitgramLabel(perk.text, font: Font.regular(15.0), color: self.secondaryTextColor, alignment: .center)
        column.addArrangedSubview(text)
        column.setCustomSpacing(20.0, after: text)

        let compare = UIStackView()
        compare.axis = .horizontal
        compare.alignment = .fill
        compare.distribution = .fillEqually
        compare.spacing = 10.0
        compare.addArrangedSubview(self.makeCompareBox(label: ChitgramStrings.get(639), value: perk.free, colors: nil))
        compare.addArrangedSubview(self.makeCompareBox(label: "\u{2B50} Premium", value: perk.premium, colors: perk.colors))
        column.addArrangedSubview(compare)
        var last: UIView = compare

        if !isActive {
            column.setCustomSpacing(22.0, after: last)
            let button = ChitgramShineButton(colors: ChitgramPremiumColors.hero, action: { [weak self] in
                guard let self else {
                    return
                }
                self.openSheet?.dismiss(completion: { [weak self] in
                    self?.buyPressed()
                })
            })
            button.title = ChitgramStrings.get(427)
            chitgramFix(button, height: 50.0)
            column.addArrangedSubview(button)
            last = button
        }
        if let open = perk.open {
            column.setCustomSpacing(isActive ? 18.0 : 6.0, after: last)
            column.addArrangedSubview(self.makeTextButton(ChitgramStrings.get(660), action: { [weak self] in
                guard let self else {
                    return
                }
                self.openSheet?.dismiss(completion: open)
            }))
        }
        self.present(sheetContent: column)
    }

    private func makeCompareBox(label: String, value: String, colors: [UIColor]?) -> UIView {
        let box = UIView()
        box.layer.cornerRadius = 16.0
        box.clipsToBounds = true
        if let colors {
            let gradient = ChitgramGradientView(colors: colors)
            box.addSubview(gradient)
            chitgramPin(gradient, to: box)
        } else {
            box.backgroundColor = self.primaryTextColor.withAlphaComponent(0.055)
        }
        let stack = chitgramColumn(spacing: 3.0)
        stack.addArrangedSubview(chitgramLabel(label, font: Font.semibold(12.5), color: colors != nil ? UIColor(white: 1.0, alpha: 0.85) : self.secondaryTextColor, alignment: .center))
        stack.addArrangedSubview(chitgramLabel(value, font: Font.semibold(15.5), color: colors != nil ? .white : self.primaryTextColor, alignment: .center))
        box.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: box.topAnchor, constant: 12.0),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: box.bottomAnchor, constant: -12.0),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10.0),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10.0)
        ])
        return box
    }

    /// The price against the Stars balance. Paid in Telegram Stars, so the gold star heads the sheet.
    private func showPay(plan: ChitgramPremium.Plan) {
        let column = chitgramColumn()
        let star = ChitgramStarHeaderView(theme: self.theme, colors: [UIColor(rgb: 0xe57d02), UIColor(rgb: 0xf09903), UIColor(rgb: 0xf9b004), UIColor(rgb: 0xfdd219)], particleColor: UIColor(rgb: 0xf9b004))
        chitgramFix(star, height: 140.0)
        column.addArrangedSubview(star)
        column.setCustomSpacing(2.0, after: star)
        let title = chitgramLabel(ChitgramStrings.get(427), font: Font.bold(22.0), color: self.primaryTextColor, alignment: .center)
        column.addArrangedSubview(title)
        column.setCustomSpacing(2.0, after: title)
        let planTitle = chitgramLabel(chitgramPlanTitle(plan), font: Font.regular(15.0), color: self.secondaryTextColor, alignment: .center)
        column.addArrangedSubview(planTitle)
        column.setCustomSpacing(10.0, after: planTitle)
        let price = chitgramLabel("\(chitgramFormatStars(plan.stars)) \u{2B50}", font: Font.bold(34.0), color: ChitgramPremiumColors.goldDeep, alignment: .center, lines: 1)
        column.addArrangedSubview(price)
        column.setCustomSpacing(16.0, after: price)

        let isShort = self.balance.map { $0 < plan.stars } ?? false
        let info = UIStackView()
        info.axis = .horizontal
        info.alignment = .center
        info.spacing = 8.0
        info.addArrangedSubview(chitgramLabel(ChitgramStrings.get(654), font: Font.regular(15.0), color: self.secondaryTextColor, lines: 1))
        let balanceValue = chitgramLabel(self.balance.map { "\(chitgramFormatStars($0)) \u{2B50}" } ?? "\u{2026}", font: Font.semibold(15.0), color: self.primaryTextColor, alignment: .right, lines: 1)
        balanceValue.setContentCompressionResistancePriority(.required, for: .horizontal)
        info.addArrangedSubview(balanceValue)
        let infoBox = UIView()
        infoBox.backgroundColor = self.primaryTextColor.withAlphaComponent(0.047)
        infoBox.layer.cornerRadius = 14.0
        infoBox.clipsToBounds = true
        infoBox.addSubview(info)
        chitgramPin(info, to: infoBox, top: 12.0, left: 16.0, bottom: 12.0, right: 16.0)
        column.addArrangedSubview(infoBox)
        var last: UIView = infoBox
        if isShort, let balance = self.balance {
            column.setCustomSpacing(8.0, after: last)
            let missing = chitgramLabel(ChitgramStrings.format(655, chitgramFormatStars(plan.stars - balance)), font: Font.regular(14.0), color: self.theme.list.itemDestructiveColor, alignment: .center)
            column.addArrangedSubview(missing)
            last = missing
        }
        column.setCustomSpacing(18.0, after: last)
        let button = ChitgramShineButton(colors: isShort ? [ChitgramPremiumColors.gold, ChitgramPremiumColors.goldDeep] : ChitgramPremiumColors.hero, action: { [weak self] in
            guard let self else {
                return
            }
            self.openSheet?.dismiss()
            self.purchase(plan: plan)
        })
        button.title = isShort ? ChitgramStrings.get(657) : ChitgramStrings.format(656, chitgramFormatStars(plan.stars))
        chitgramFix(button, height: 52.0)
        column.addArrangedSubview(button)
        column.setCustomSpacing(12.0, after: button)
        let note = chitgramLabel(ChitgramStrings.get(436), font: Font.regular(12.5), color: self.secondaryTextColor, alignment: .center)
        column.addArrangedSubview(note)
        column.setCustomSpacing(4.0, after: note)
        column.addArrangedSubview(self.makeTextButton(self.presentationData.strings.Common_Cancel, action: { [weak self] in
            self?.openSheet?.dismiss()
        }))
        self.present(sheetContent: column)
    }

    private func showWelcome(until: Int32) {
        let column = chitgramColumn()
        let star = ChitgramStarHeaderView(theme: self.theme, colors: [ChitgramPremiumColors.blue, ChitgramPremiumColors.indigo, ChitgramPremiumColors.violet, ChitgramPremiumColors.violet], particleColor: ChitgramPremiumColors.violet)
        chitgramFix(star, height: 170.0)
        column.addArrangedSubview(star)
        column.setCustomSpacing(4.0, after: star)
        let title = chitgramLabel(ChitgramStrings.get(659), font: Font.bold(24.0), color: self.primaryTextColor, alignment: .center)
        column.addArrangedSubview(title)
        column.setCustomSpacing(6.0, after: title)
        let text = chitgramLabel(ChitgramStrings.format(428, chitgramFormatDate(until)), font: Font.regular(15.0), color: self.secondaryTextColor, alignment: .center)
        column.addArrangedSubview(text)
        column.setCustomSpacing(22.0, after: text)
        let button = ChitgramShineButton(colors: ChitgramPremiumColors.hero, action: { [weak self] in
            self?.openSheet?.dismiss()
        })
        button.title = ChitgramStrings.get(661)
        chitgramFix(button, height: 50.0)
        column.addArrangedSubview(button)
        self.present(sheetContent: column)
    }

    // MARK: Layout

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let y = scrollView.contentOffset.y + scrollView.contentInset.top
        // Once the title has scrolled under the bar the bar shows it, as on Telegram's page.
        let showsTitle = y > 150.0
        if showsTitle != self.showsTitle {
            self.showsTitle = showsTitle
            self.title = showsTitle ? ChitgramStrings.get(427) : nil
        }
        // The star drifts up a little slower than the page and fades as it goes.
        self.starHeader?.transform = CGAffineTransform(translationX: 0.0, y: max(0.0, y) * 0.35)
        self.starHeader?.alpha = max(0.0, min(1.0, 1.0 - y / 220.0))
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)

        self.navigationHeight = self.navigationLayout(layout: layout).navigationFrame.maxY
        self.bottomInset = layout.intrinsicInsets.bottom

        let sideInset: CGFloat = 16.0
        let captionSize = self.bottomCaption.sizeThatFits(CGSize(width: max(0.0, layout.size.width - sideInset * 2.0), height: .greatestFiniteMagnitude))
        let panelHeight: CGFloat = 12.0 + 50.0 + 8.0 + ceil(captionSize.height) + 10.0 + self.bottomInset
        self.bottomPanel.frame = CGRect(x: 0.0, y: layout.size.height - panelHeight, width: layout.size.width, height: panelHeight)
        self.buyButton?.frame = CGRect(x: sideInset, y: 12.0, width: max(0.0, layout.size.width - sideInset * 2.0), height: 50.0)
        self.bottomCaption.frame = CGRect(x: sideInset, y: 70.0, width: max(0.0, layout.size.width - sideInset * 2.0), height: ceil(captionSize.height))

        self.scrollView.frame = CGRect(origin: CGPoint(), size: layout.size)
        self.scrollView.contentInset = UIEdgeInsets(top: self.navigationHeight, left: 0.0, bottom: panelHeight + 16.0, right: 0.0)
        self.scrollView.scrollIndicatorInsets = self.scrollView.contentInset

        self.openSheet?.frame = CGRect(origin: CGPoint(), size: layout.size)
    }
}

public func chitgramPremiumController(context: AccountContext) -> ViewController {
    return ChitgramPremiumScreen(context: context)
}

/// Why no account can be added, and how Premium lifts it (Android `AccountLimit.showLimit`).
public func chitgramShowAccountLimit(context: AccountContext, hasPremium: Bool, present: @escaping (ViewController) -> Void, push: @escaping (ViewController) -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    if hasPremium {
        present(textAlertController(context: context, title: ChitgramStrings.get(600), text: ChitgramStrings.format(603, ChitgramLimits.premiumAccounts), actions: [
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
        ]))
    } else {
        present(textAlertController(context: context, title: ChitgramStrings.get(600), text: ChitgramStrings.format(601, ChitgramLimits.freeAccounts, ChitgramLimits.premiumAccounts), actions: [
            TextAlertAction(type: .genericAction, title: ChitgramStrings.get(581), action: {}),
            TextAlertAction(type: .defaultAction, title: ChitgramStrings.get(602), action: {
                push(chitgramPremiumController(context: context))
            })
        ]))
    }
}
