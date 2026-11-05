import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ChitgramCore

/// Chitgram: the share sheet's categories (Android `ShareBar`): All, each folder, Personal, Groups, Channels, Bots
/// narrow the chat grid, and a line under them names the category with its size and ticks all of it at once.
enum ChitgramShareCategory: Equatable {
    case all
    case personal
    case groups
    case channels
    case bots
    case folder(Int32)
}

/// Ticking a whole category is capped, more with Chitgram Premium (Android `FREE_BULK`, `PREMIUM_BULK`).
let chitgramShareFreeBulk = 10
let chitgramSharePremiumBulk = 100

/// Past this many chats a share goes out one by one (Android `PACE_FROM`, `SharePacer`).
let chitgramSharePaceFrom = 10
let chitgramSharePaceGap: Double = 2.0

func chitgramShareBulkLimit() -> Int {
    return ChitgramKeywords.shared.isPremium ? chitgramSharePremiumBulk : chitgramShareFreeBulk
}

/// Whether `peer` belongs to `category`. A folder is judged by its rules as far as the sheet can see them: chats it
/// names, chats it excludes, and its kinds of chat (contacts and non-contacts both count as personal chats here).
func chitgramShareCategoryContains(_ category: ChitgramShareCategory, peer: EngineRenderedPeer, folders: [ChatListFilter]) -> Bool {
    guard let mainPeer = peer.chatMainPeer else {
        return false
    }
    enum Kind {
        case personal
        case bot
        case group
        case channel
    }
    let kind: Kind
    switch mainPeer {
    case let .user(user):
        kind = user.botInfo != nil ? .bot : .personal
    case .secretChat:
        kind = .personal
    case .legacyGroup, .community:
        kind = .group
    case let .channel(channel):
        if case .broadcast = channel.info {
            kind = .channel
        } else {
            kind = .group
        }
    }
    switch category {
    case .all:
        return true
    case .personal:
        return kind == .personal
    case .groups:
        return kind == .group
    case .channels:
        return kind == .channel
    case .bots:
        return kind == .bot
    case let .folder(id):
        for filter in folders {
            guard case let .filter(filterId, _, _, data) = filter, filterId == id else {
                continue
            }
            if data.excludePeers.contains(peer.peerId) {
                return false
            }
            if data.includePeers.peers.contains(peer.peerId) || data.includePeers.pinnedPeers.contains(peer.peerId) {
                return true
            }
            switch kind {
            case .personal:
                return data.categories.contains(.contacts) || data.categories.contains(.nonContacts)
            case .bot:
                return data.categories.contains(.bots)
            case .group:
                return data.categories.contains(.groups)
            case .channel:
                return data.categories.contains(.channels)
            }
        }
        return false
    }
}

/// The row of categories and the line under it. Lives in the grid's scroll view just above the first row, so it
/// scrolls with the chats and slides under the sheet's header.
final class ChitgramShareCategoryBar: UIView {
    static let height: CGFloat = 64.0

    private let scrollView = UIScrollView()
    private var chips: [(category: ChitgramShareCategory, button: UIButton)] = []
    private let captionLabel = UILabel()
    private let actionButton = UIButton(type: .system)

    var selected: ((ChitgramShareCategory) -> Void)?
    var action: (() -> Void)?

    private var theme: PresentationTheme
    private var current: ChitgramShareCategory = .all

    init(theme: PresentationTheme) {
        self.theme = theme
        super.init(frame: CGRect())
        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.alwaysBounceHorizontal = true
        self.addSubview(self.scrollView)
        self.captionLabel.font = UIFont.systemFont(ofSize: 13.0)
        self.addSubview(self.captionLabel)
        self.actionButton.titleLabel?.font = UIFont.systemFont(ofSize: 13.0, weight: .medium)
        self.actionButton.contentHorizontalAlignment = .right
        self.actionButton.addTarget(self, action: #selector(self.actionPressed), for: .touchUpInside)
        self.addSubview(self.actionButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(categories: [(ChitgramShareCategory, String)], current: ChitgramShareCategory, caption: String, actionTitle: String?, theme: PresentationTheme) {
        self.theme = theme
        self.current = current
        if self.chips.map({ $0.category }) != categories.map({ $0.0 }) || self.chips.map({ $0.button.title(for: .normal) ?? "" }) != categories.map({ $0.1 }) {
            for chip in self.chips {
                chip.button.removeFromSuperview()
            }
            self.chips = categories.map { category, title in
                let button = UIButton(type: .custom)
                button.setTitle(title, for: .normal)
                button.titleLabel?.font = UIFont.systemFont(ofSize: 14.0, weight: .medium)
                button.layer.cornerRadius = 15.0
                button.addTarget(self, action: #selector(self.chipPressed(_:)), for: .touchUpInside)
                self.scrollView.addSubview(button)
                return (category, button)
            }
        }
        for chip in self.chips {
            let isCurrent = chip.category == current
            chip.button.backgroundColor = isCurrent ? theme.actionSheet.controlAccentColor : theme.actionSheet.controlAccentColor.withAlphaComponent(0.1)
            chip.button.setTitleColor(isCurrent ? theme.actionSheet.opaqueItemBackgroundColor : theme.actionSheet.controlAccentColor, for: .normal)
        }
        self.captionLabel.text = caption
        self.captionLabel.textColor = theme.actionSheet.secondaryTextColor
        self.actionButton.setTitle(actionTitle, for: .normal)
        self.actionButton.setTitleColor(theme.actionSheet.controlAccentColor, for: .normal)
        self.actionButton.isHidden = actionTitle == nil
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = self.bounds.width
        self.scrollView.frame = CGRect(x: 0.0, y: 4.0, width: width, height: 30.0)
        var x: CGFloat = 12.0
        for chip in self.chips {
            let title = chip.button.title(for: .normal) ?? ""
            let textWidth = ceil((title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 14.0, weight: .medium)]).width)
            chip.button.frame = CGRect(x: x, y: 0.0, width: max(44.0, min(240.0, textWidth + 24.0)), height: 30.0)
            x += chip.button.frame.width + 8.0
        }
        self.scrollView.contentSize = CGSize(width: x + 4.0, height: 30.0)
        let actionWidth: CGFloat = self.actionButton.isHidden ? 0.0 : min(width * 0.5, self.actionButton.sizeThatFits(CGSize(width: width, height: 24.0)).width)
        self.actionButton.frame = CGRect(x: width - 16.0 - actionWidth, y: 38.0, width: actionWidth, height: 24.0)
        self.captionLabel.frame = CGRect(x: 16.0, y: 38.0, width: width - 32.0 - actionWidth - 8.0, height: 24.0)
    }

    @objc private func chipPressed(_ sender: UIButton) {
        if let chip = self.chips.first(where: { $0.button === sender }) {
            self.selected?(chip.category)
        }
    }

    @objc private func actionPressed() {
        self.action?()
    }
}

/// Sends past `chitgramSharePaceFrom` chats one by one, `chitgramSharePaceGap` seconds apart, so a burst of identical
/// shares does not read as flooding (Android `SharePacer`). The first chat goes now and the sheet follows it; the
/// rest keep going after the sheet closes, and a note says when they start and when the last has gone.
func chitgramPacedShareSignals<T>(_ signals: [Signal<T, NoError>], notify: @escaping (String) -> Void) -> [Signal<T, NoError>] {
    if signals.count <= chitgramSharePaceFrom {
        return signals
    }
    let count = signals.count
    let minutes = max(1, Int(Double(count - 1) * chitgramSharePaceGap / 60.0) + 1)
    notify(ChitgramStrings.format(626, count, minutes))
    for i in 1 ..< count {
        let isLast = i == count - 1
        let _ = (Signal<Never, NoError>.complete()
        |> delay(Double(i) * chitgramSharePaceGap, queue: .mainQueue())
        |> then(signals[i] |> ignoreValues)
        |> deliverOnMainQueue).startStandalone(completed: {
            if isLast {
                notify(ChitgramStrings.format(627, count))
            }
        })
    }
    return [signals[0]]
}
