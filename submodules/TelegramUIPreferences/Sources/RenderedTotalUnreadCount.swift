import Foundation
import ChitgramCore
import TelegramCore
import SwiftSignalKit

public enum RenderedTotalUnreadCountType {
    case raw
    case filtered
}

public func renderedTotalUnreadCount(inAppSettings: InAppNotificationSettings, totalUnreadState: EngineChatListTotalUnreadState) -> (Int32, RenderedTotalUnreadCountType) {
    let type: RenderedTotalUnreadCountType
    switch inAppSettings.totalUnreadCountDisplayStyle {
        case .filtered:
            type = .filtered
    }
    return (totalUnreadState.count(for: inAppSettings.totalUnreadCountDisplayStyle.category, in: inAppSettings.totalUnreadCountDisplayCategory.statsType, with: inAppSettings.totalUnreadCountIncludeTags), type)
}

// Chitgram: what the chats in the secret folder add to the total, which never counts them (Android
// NotificationsController). Muted chats are not in the total to begin with.
private func chitgramSecretUnread(engine: TelegramEngine) -> Signal<(messages: Int32, chats: Int32), NoError> {
    return ChitgramPreferences.shared.changes
    |> map { _ -> Set<Int64> in
        return ChitgramLock.secretChats()
    }
    |> distinctUntilChanged
    |> mapToSignal { chats -> Signal<(messages: Int32, chats: Int32), NoError> in
        if chats.isEmpty {
            return .single((messages: 0, chats: 0))
        }
        return engine.data.subscribe(
            EngineDataMap(chats.map { TelegramEngine.EngineData.Item.Messages.PeerReadCounters(id: EnginePeer.Id($0)) })
        )
        |> map { counters -> (messages: Int32, chats: Int32) in
            var messages: Int32 = 0
            var unreadChats: Int32 = 0
            for (_, value) in counters where !value.isMuted {
                messages += value.count
                if value.isUnread {
                    unreadChats += 1
                }
            }
            return (messages: messages, chats: unreadChats)
        }
    }
}

public func renderedTotalUnreadCount(accountManager: AccountManager<TelegramAccountManagerTypes>, engine: TelegramEngine) -> Signal<(Int32, RenderedTotalUnreadCountType), NoError> {
    return combineLatest(
        accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.inAppNotificationSettings]),
        engine.data.subscribe(
            TelegramEngine.EngineData.Item.Messages.TotalReadCounters()
        ),
        chitgramSecretUnread(engine: engine)
    )
    |> map { sharedData, totalReadCounters, secretUnread -> (Int32, RenderedTotalUnreadCountType) in
        let inAppSettings: InAppNotificationSettings
        if let value = sharedData.entries[ApplicationSpecificSharedDataKeys.inAppNotificationSettings]?.get(InAppNotificationSettings.self) {
            inAppSettings = value
        } else {
            inAppSettings = .defaultSettings
        }
        let type: RenderedTotalUnreadCountType
        switch inAppSettings.totalUnreadCountDisplayStyle {
            case .filtered:
                type = .filtered
        }
        let total = totalReadCounters.count(for: inAppSettings.totalUnreadCountDisplayStyle.category, in: inAppSettings.totalUnreadCountDisplayCategory.statsType, with: inAppSettings.totalUnreadCountIncludeTags)
        let secret = inAppSettings.totalUnreadCountDisplayCategory == .chats ? secretUnread.chats : secretUnread.messages
        return (max(0, total - secret), type)
    }
    |> distinctUntilChanged(isEqual: { lhs, rhs in
        return lhs == rhs
    })
}
