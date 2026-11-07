import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import Display
import ContextUI
import NovagramMessenger

// Chitgram: Novagram's ads ran on its closed NovagramAds SDK and its own ad server, which are not ours to ship. This
// module keeps the API the Telegram-owned hooks call, with no ads of its own: every "if ours" answers no, and every
// slot shows Telegram's own ad unchanged, hidden while the "Remove all ads" switch (`NovagramShowAdsGate`) is on.

public enum NovagramSponsored {
    /// No ad SDK in this build.
    public static var isConfigured: Bool {
        return false
    }

    /// No sponsored message is ours.
    public static func isOurs(opaqueId: Data) -> Bool {
        return false
    }

    /// Mirrors `source` while ads are allowed; emits `empty` while "Remove all ads" is on.
    static func gated<T>(empty: T, _ source: Signal<T, NoError>) -> Signal<T, NoError> {
        return NovagramShowAdsGate.gate(empty: empty, source: source)
    }

    /// The chat-list notice slot while "Remove all ads" is on: Telegram's promo and server notices are dropped,
    /// security notices (`isSecurity`) stay.
    public static func gatedNotice<T: Equatable>(_ source: Signal<T?, NoError>, isSecurity: @escaping (T) -> Bool) -> Signal<T?, NoError> {
        return combineLatest(source, NovagramShowAdsGate.enabledSignal |> distinctUntilChanged)
        |> map { notice, adsShown -> T? in
            guard !adsShown, let notice else {
                return notice
            }
            return isSecurity(notice) ? notice : nil
        }
        |> distinctUntilChanged
    }

    @discardableResult
    public static func recordViewIfOurs(opaqueId: Data) -> Bool {
        return false
    }

    public static func recordClickIfOurs(opaqueId: Data, thenOpen open: @escaping () -> Void) -> Bool {
        return false
    }

    public static func recordVideoOpenIfOurs(opaqueId: Data) -> Bool {
        return false
    }

    public static func hideIfOurs(opaqueId: Data) -> Bool {
        return false
    }
}

public enum NovagramAdMenu {
    public static func contextMenuItems(opaqueId: Data, context: AccountContext, present: @escaping (ViewController) -> Void) -> [ContextMenuItem]? {
        return nil
    }

    public static func presentIfOurs(opaqueId: Data, context: AccountContext, present: @escaping (ViewController) -> Void) -> Bool {
        return false
    }
}

/// A chat-list banner; none is ever produced.
public struct NovagramBannerNotice: Equatable {
    public let id: String
    public let url: String
    public let title: String
    public let text: String
}

public enum NovagramBannerAds {
    public static func bannerNotice(context: AccountContext) -> Signal<NovagramBannerNotice?, NoError> {
        return .single(nil)
    }

    public static func urlForTap(noticeId: String, url: String, context: AccountContext) -> String? {
        return nil
    }

    public static func dismissIfOurs(noticeId: String, context: AccountContext) -> Bool {
        return false
    }
}

public enum NovagramBotAds {
    /// Telegram's own bot-panel ad, hidden while "Remove all ads" is on.
    public static func panelMessage(context: AccountContext, peerId: EnginePeer.Id, fallback: Signal<EngineRawMessage?, NoError>) -> Signal<EngineRawMessage?, NoError> {
        guard peerId.namespace == Namespaces.Peer.CloudUser else {
            return fallback
        }
        return NovagramSponsored.gated(empty: nil, fallback)
    }
}

/// The ad-source tuple `ChatHistoryListNode` consumes (`adMessagesContext.state`).
public typealias NovagramAdMessagesState = (interPostInterval: Int32?, messages: [EngineRawMessage], startDelay: Int32?, betweenDelay: Int32?)

public enum NovagramChannelAds {
    /// Telegram's own channel ads, hidden while "Remove all ads" is on.
    public static func adMessages(context: AccountContext, peerId: EnginePeer.Id, fallback: Signal<NovagramAdMessagesState, NoError>) -> Signal<NovagramAdMessagesState, NoError> {
        let empty: NovagramAdMessagesState = (nil, [], nil, nil)
        return NovagramSponsored.gated(empty: empty, fallback)
    }
}

/// A promoted channel or bot for a search query; none is ever produced.
public struct NovagramPromotedPeer: Equatable {
    public let peer: EnginePeer
    public let token: String
}

public enum NovagramSearchAds {
    /// Telegram's own search ads, hidden while "Remove all ads" is on.
    public static func adPeers(context: AccountContext, query: String, telegramAdPeers: Signal<[AdPeer], NoError>) -> Signal<([AdPeer], NovagramPromotedPeer?), NoError> {
        let empty: ([AdPeer], NovagramPromotedPeer?) = ([], nil)
        return NovagramSponsored.gated(empty: empty, telegramAdPeers |> map { adPeers -> ([AdPeer], NovagramPromotedPeer?) in
            return (adPeers, nil)
        })
    }

    public static func recordView(token: String) {
    }

    public static func recordClick(token: String, thenOpen open: @escaping () -> Void) {
        open()
    }

    public static func presentMenu(token: String, context: AccountContext, present: @escaping (ViewController) -> Void) {
    }
}
