import SwiftSignalKit
import Postbox

public extension TelegramEngine.EngineData.Item.ChatList {
    /// Chitgram: the account's folders with their rules, for screens that sort chats by them without a chat list of
    /// their own (the share sheet's categories, Android `ShareBar`).
    struct ChitgramFilters: TelegramEngineDataItem, PostboxViewDataItem {
        public typealias Result = [ChatListFilter]

        public init() {
        }

        var key: PostboxViewKey {
            return .preferences(keys: Set([PreferencesKeys.chatListFilters]))
        }

        func extract(view: PostboxView) -> Result {
            guard let view = view as? PreferencesView else {
                preconditionFailure()
            }
            let state = view.values[PreferencesKeys.chatListFilters]?.get(ChatListFiltersState.self) ?? ChatListFiltersState.default
            return state.filters
        }
    }
}
