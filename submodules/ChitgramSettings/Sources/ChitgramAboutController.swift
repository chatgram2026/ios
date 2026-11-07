import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import AppBundle
import ShareController
import NovagramReviewPromptCore
import ChitgramCore

/// The Telegram release this build is made from (Novagram's base). Bump it with the next upstream update.
private let chitgramAboutTelegramBase = "13.1.1"
/// The one person users write to: support, questions, payments (Android `AboutScreen.SUPPORT_ADMIN`).
private let chitgramAboutSupportAdmin = "shoxxohs"
/// The official channel (Android `AboutScreen.CHANNEL`).
private let chitgramAboutChannel = "chitgram_org"
/// The app's App Store page, which the share text links to.
private let chitgramAboutAppStoreLink = "https://apps.apple.com/app/id\(ReviewPromptLinks.chitgramAppStoreId)"

/// Android's "Leave your feedback on Google Play" (604) for iOS: Apple does not accept another store's name here.
private func chitgramAboutReviewSubtitle() -> String {
    switch ChitgramStrings.language {
    case .uz:
        return "App Store'da fikringizni qoldiring"
    case .ru:
        return "Оставьте отзыв в App Store"
    case .en:
        return "Leave your feedback on the App Store"
    }
}

private func chitgramAboutLabel(_ text: String?, font: UIFont, color: UIColor, alignment: NSTextAlignment = .natural, lines: Int = 0) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = font
    label.textColor = color
    label.textAlignment = alignment
    label.numberOfLines = lines
    return label
}

private func chitgramAboutPin(_ view: UIView, to parent: UIView, top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: parent.topAnchor, constant: top),
        view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: left),
        view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -bottom),
        view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -right)
    ])
}

private func chitgramAboutFix(_ view: UIView, width: CGFloat, height: CGFloat) {
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        view.widthAnchor.constraint(equalToConstant: width),
        view.heightAnchor.constraint(equalToConstant: height)
    ])
}

private func chitgramAboutColumn(spacing: CGFloat = 0.0) -> UIStackView {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = spacing
    return stack
}

/// A settings-style row that highlights while pressed (Android `selectableItemBackground`).
private final class ChitgramAboutRow: UIControl {
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

/// Settings ▸ Chitgram ▸ About (Android `org.fenixuz.ui.about.AboutScreen`): the logo with the app and Telegram
/// versions, then rounded cards to rate and share the app, the official channel, the support admin and the company.
private final class ChitgramAboutScreen: ViewController {
    private let context: AccountContext
    private let presentationData: PresentationData
    private let scrollView = UIScrollView()
    private let column = chitgramAboutColumn(spacing: 12.0)
    private let openDisposable = MetaDisposable()

    private var theme: PresentationTheme {
        return self.presentationData.theme
    }

    init(context: AccountContext) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }

        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))

        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.title = ChitgramStrings.get(355)
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.openDisposable.dispose()
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.theme.list.blocksBackgroundColor
        self.displayNodeDidLoad()

        self.scrollView.alwaysBounceVertical = true
        self.scrollView.showsVerticalScrollIndicator = false
        self.scrollView.contentInsetAdjustmentBehavior = .never
        self.displayNode.view.addSubview(self.scrollView)

        // The cards keep a comfortable width on an iPad or in landscape, centred (Android: at most 560).
        self.column.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.addSubview(self.column)
        let frameGuide = self.scrollView.frameLayoutGuide
        let contentGuide = self.scrollView.contentLayoutGuide
        let fullWidth = self.column.widthAnchor.constraint(equalTo: frameGuide.widthAnchor, constant: -24.0)
        fullWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            contentGuide.widthAnchor.constraint(equalTo: frameGuide.widthAnchor),
            self.column.topAnchor.constraint(equalTo: contentGuide.topAnchor, constant: 12.0),
            self.column.bottomAnchor.constraint(equalTo: contentGuide.bottomAnchor, constant: -16.0),
            self.column.centerXAnchor.constraint(equalTo: frameGuide.centerXAnchor),
            self.column.widthAnchor.constraint(lessThanOrEqualToConstant: 560.0),
            self.column.widthAnchor.constraint(lessThanOrEqualTo: frameGuide.widthAnchor, constant: -24.0),
            fullWidth
        ])

        self.column.addArrangedSubview(self.makeHeroCard())
        self.column.addArrangedSubview(self.makeRateCard())
        self.column.addArrangedSubview(self.makeChannelCard())
        self.column.addArrangedSubview(self.makeSupportCard())
        self.column.addArrangedSubview(self.makeCompanyCard())
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)

        let navigationHeight = self.navigationLayout(layout: layout).navigationFrame.maxY
        self.scrollView.frame = CGRect(origin: CGPoint(), size: layout.size)
        self.scrollView.contentInset = UIEdgeInsets(top: navigationHeight, left: 0.0, bottom: layout.intrinsicInsets.bottom, right: 0.0)
        self.scrollView.scrollIndicatorInsets = self.scrollView.contentInset
    }

    // MARK: Cards

    private func makeCard() -> UIStackView {
        let card = chitgramAboutColumn()
        let background = UIView()
        background.backgroundColor = self.theme.list.itemBlocksBackgroundColor
        card.insertSubview(background, at: 0)
        chitgramAboutPin(background, to: card, top: 0.0, left: 0.0, bottom: 0.0, right: 0.0)
        card.layer.cornerRadius = 18.0
        card.clipsToBounds = true
        return card
    }

    private func makeHeader(_ title: String) -> UIView {
        let box = UIView()
        let label = chitgramAboutLabel(title, font: Font.semibold(15.0), color: self.theme.list.itemAccentColor, lines: 1)
        box.addSubview(label)
        chitgramAboutPin(label, to: box, top: 14.0, left: 16.0, bottom: 8.0, right: 16.0)
        return box
    }

    /// A tappable row: a small rounded coloured icon, a title with its subtitle, and a chevron (Android `row`).
    private func makeRow(symbol: String, color: UIColor, title: String, subtitle: String?, action: @escaping () -> Void) -> UIView {
        let row = ChitgramAboutRow(highlightColor: self.theme.list.itemHighlightedBackgroundColor, action: action)

        let tile = UIView()
        tile.backgroundColor = color
        tile.layer.cornerRadius = 9.0
        tile.isUserInteractionEnabled = false
        let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .semibold)))
        icon.tintColor = .white
        icon.contentMode = .center
        tile.addSubview(icon)
        chitgramAboutPin(icon, to: tile, top: 0.0, left: 0.0, bottom: 0.0, right: 0.0)
        chitgramAboutFix(tile, width: 32.0, height: 32.0)

        let texts = chitgramAboutColumn(spacing: 1.0)
        texts.isUserInteractionEnabled = false
        texts.addArrangedSubview(chitgramAboutLabel(title, font: Font.regular(16.0), color: self.theme.list.itemPrimaryTextColor, lines: 1))
        if let subtitle, !subtitle.isEmpty {
            texts.addArrangedSubview(chitgramAboutLabel(subtitle, font: Font.regular(13.0), color: self.theme.list.itemSecondaryTextColor, lines: 2))
        }
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let arrow = UIImageView(image: UIImage(bundleImageName: "Chitgram/Perk/Arrow")?.withRenderingMode(.alwaysTemplate))
        arrow.tintColor = self.theme.list.disclosureArrowColor
        arrow.contentMode = .center
        arrow.isUserInteractionEnabled = false
        chitgramAboutFix(arrow, width: 24.0, height: 24.0)

        let line = UIStackView(arrangedSubviews: [tile, texts, arrow])
        line.axis = .horizontal
        line.alignment = .center
        line.spacing = 14.0
        line.isUserInteractionEnabled = false
        row.addSubview(line)
        chitgramAboutPin(line, to: row, top: 12.0, left: 16.0, bottom: 12.0, right: 12.0)
        return row
    }

    private func makeHeroCard() -> UIView {
        let card = self.makeCard()
        card.alignment = .center
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = UIEdgeInsets(top: 22.0, left: 16.0, bottom: 20.0, right: 16.0)

        // The logo the intro screen shows (Android `logo_fenix`), as a rounded tile.
        let logo = UIImageView(image: UIImage(named: "novagram_logo") ?? UIImage(bundleImageName: "Chitgram/BadgeTile"))
        logo.contentMode = .scaleAspectFit
        logo.layer.cornerRadius = 22.0
        logo.clipsToBounds = true
        chitgramAboutFix(logo, width: 96.0, height: 96.0)
        card.addArrangedSubview(logo)
        card.setCustomSpacing(12.0, after: logo)

        let name = chitgramAboutLabel("Chitgram", font: Font.bold(22.0), color: self.theme.list.itemPrimaryTextColor, alignment: .center, lines: 1)
        card.addArrangedSubview(name)
        card.setCustomSpacing(2.0, after: name)
        let tagline = chitgramAboutLabel(ChitgramStrings.get(366), font: Font.regular(14.0), color: self.theme.list.itemSecondaryTextColor, alignment: .center, lines: 1)
        card.addArrangedSubview(tagline)
        card.setCustomSpacing(18.0, after: tagline)

        // What we ship, and the Telegram release it is made from.
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        let chips = UIStackView(arrangedSubviews: [
            self.makeChip(label: "Chitgram", value: version.isEmpty ? "" : "v" + version),
            self.makeChip(label: "Telegram", value: chitgramAboutTelegramBase)
        ])
        chips.axis = .horizontal
        chips.alignment = .fill
        chips.distribution = .fillEqually
        chips.spacing = 10.0
        card.addArrangedSubview(chips)
        chips.widthAnchor.constraint(equalTo: card.layoutMarginsGuide.widthAnchor).isActive = true
        return card
    }

    private func makeChip(label: String, value: String) -> UIView {
        let box = UIView()
        box.backgroundColor = self.theme.list.blocksBackgroundColor
        box.layer.cornerRadius = 14.0
        box.clipsToBounds = true
        let stack = chitgramAboutColumn(spacing: 2.0)
        stack.addArrangedSubview(chitgramAboutLabel(label, font: Font.regular(12.0), color: self.theme.list.itemSecondaryTextColor, alignment: .center, lines: 1))
        stack.addArrangedSubview(chitgramAboutLabel(value, font: Font.semibold(15.0), color: self.theme.list.itemAccentColor, alignment: .center, lines: 1))
        box.addSubview(stack)
        chitgramAboutPin(stack, to: box, top: 10.0, left: 14.0, bottom: 10.0, right: 14.0)
        return box
    }

    private func makeRateCard() -> UIView {
        let card = self.makeCard()
        card.addArrangedSubview(self.makeHeader(ChitgramStrings.get(608)))
        card.addArrangedSubview(self.makeRow(symbol: "star.fill", color: UIColor(rgb: 0xFFB800), title: ChitgramStrings.get(359), subtitle: chitgramAboutReviewSubtitle(), action: { [weak self] in
            self?.openReview()
        }))
        card.addArrangedSubview(self.makeRow(symbol: "square.and.arrow.up", color: UIColor(rgb: 0x2CBE8C), title: ChitgramStrings.get(605), subtitle: ChitgramStrings.get(607), action: { [weak self] in
            self?.share()
        }))
        return card
    }

    private func makeChannelCard() -> UIView {
        let card = self.makeCard()
        card.addArrangedSubview(self.makeHeader(ChitgramStrings.get(404)))
        card.addArrangedSubview(self.makeRow(symbol: "megaphone.fill", color: UIColor(rgb: 0x0A84FF), title: ChitgramStrings.get(405), subtitle: "@" + chitgramAboutChannel, action: { [weak self] in
            self?.openUsername(chitgramAboutChannel)
        }))
        return card
    }

    private func makeSupportCard() -> UIView {
        let card = self.makeCard()
        card.addArrangedSubview(self.makeHeader(ChitgramStrings.get(356)))
        card.addArrangedSubview(self.makeRow(symbol: "person.fill", color: UIColor(rgb: 0x2CBE8C), title: ChitgramStrings.get(357), subtitle: "@" + chitgramAboutSupportAdmin, action: { [weak self] in
            self?.openUsername(chitgramAboutSupportAdmin)
        }))
        return card
    }

    private func makeCompanyCard() -> UIView {
        let card = self.makeCard()
        card.addArrangedSubview(self.makeHeader(ChitgramStrings.get(361)))
        let block = chitgramAboutColumn(spacing: 10.0)
        block.addArrangedSubview(chitgramAboutLabel(ChitgramStrings.get(367) + "\n" + ChitgramStrings.get(368), font: Font.regular(13.0), color: self.theme.list.itemSecondaryTextColor))
        block.addArrangedSubview(chitgramAboutLabel(ChitgramStrings.get(364), font: Font.regular(14.0), color: self.theme.list.itemSecondaryTextColor))
        let box = UIView()
        box.addSubview(block)
        chitgramAboutPin(block, to: box, top: 4.0, left: 16.0, bottom: 14.0, right: 16.0)
        card.addArrangedSubview(box)
        return card
    }

    // MARK: Actions

    private func openReview() {
        guard let url = ReviewPromptLinks.writeReviewURL() else {
            return
        }
        self.context.sharedContext.applicationBindings.openUrl(url.absoluteString)
    }

    private func share() {
        let text = ChitgramStrings.get(606) + "\n" + chitgramAboutAppStoreLink
        let controller = ShareController(context: self.context, subject: .text(text))
        self.present(controller, in: .window(.root))
    }

    /// Opens the chat with @username inside the app, like a t.me link; t.me in the browser when it cannot be found.
    private func openUsername(_ username: String) {
        let context = self.context
        self.openDisposable.set((context.engine.peers.resolvePeerByName(name: username, referrer: nil)
        |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
            switch result {
            case let .result(peer):
                return .single(peer)
            case .progress:
                return .complete()
            }
        }
        |> take(1)
        |> deliverOnMainQueue).startStrict(next: { [weak self] peer in
            guard let self else {
                return
            }
            if let peer {
                let chatController = context.sharedContext.makeChatController(context: context, chatLocation: .peer(id: peer.id), subject: nil, botStart: nil, mode: .standard(.default), params: nil)
                self.push(chatController)
            } else {
                context.sharedContext.applicationBindings.openUrl("https://t.me/" + username)
            }
        }))
    }
}

public func chitgramAboutController(context: AccountContext) -> ViewController {
    return ChitgramAboutScreen(context: context)
}
