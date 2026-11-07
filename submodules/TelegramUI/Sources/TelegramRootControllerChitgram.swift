import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChitgramCore

// Chitgram: the bottom bar as set in Settings ▸ Chitgram ▸ Sozlamalar ▸ Tab bar (Android `ChatgramTabs`).
extension TelegramRootController {
    /// The tabs in the user's order, without the hidden ones. A tab this does not know (News) stays right after
    /// Chats.
    func chitgramArrangeTabs(_ controllers: [ViewController], contacts: ViewController?, calls: ViewController?, chats: ViewController?, settings: ViewController?) -> [ViewController] {
        var byTab: [Int: ViewController] = [:]
        var others: [ViewController] = []
        for controller in controllers {
            if let contacts, controller === contacts {
                byTab[ChitgramTabs.contacts] = controller
            } else if let calls, controller === calls {
                byTab[ChitgramTabs.calls] = controller
            } else if let chats, controller === chats {
                byTab[ChitgramTabs.chats] = controller
            } else if let settings, controller === settings {
                byTab[ChitgramTabs.settings] = controller
            } else {
                others.append(controller)
            }
        }
        var result: [ViewController] = []
        for tab in ChitgramTabs.order() {
            guard let controller = byTab[tab], ChitgramTabs.isVisible(tab) else {
                continue
            }
            result.append(controller)
            if tab == ChitgramTabs.chats {
                result.append(contentsOf: others)
            }
        }
        return result.count >= ChitgramTabs.minVisible ? result : controllers
    }

    /// Where the app opens: the start tab when it is on the bar.
    func chitgramStartIndex(_ controllers: [ViewController], contacts: ViewController?, calls: ViewController?, chats: ViewController?, settings: ViewController?) -> Int? {
        let target: ViewController?
        switch ChitgramTabs.startTab() {
        case ChitgramTabs.contacts:
            target = contacts
        case ChitgramTabs.calls:
            target = calls
        case ChitgramTabs.settings:
            target = settings
        default:
            target = chats
        }
        guard let target else {
            return nil
        }
        return controllers.firstIndex(where: { $0 === target })
    }

    /// The bottom panel's extra button (Android `MainTabsActivity.addExtraButton`).
    private func chitgramExtraPressed() {
        let context = self.chitgramContext
        switch ChitgramTabs.extraButton() {
        case ChitgramTabs.extraSearch:
            self.openChatsController(activateSearch: true)
        case ChitgramTabs.extraNewMessage:
            self.chatListController?.activateCompose()
        case ChitgramTabs.extraSaved:
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
            |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
                guard let self, let peer else {
                    return
                }
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: self, context: context, chatLocation: .peer(peer)))
            })
        default:
            break
        }
    }

    /// Rebuilds the bar when the Tab bar settings change, with the inputs it was last built from.
    func chitgramObserveTabs(showCallsTab: Bool, showNewsTab: Bool) {
        if self.chitgramExtraObserver == nil {
            self.chitgramExtraObserver = NotificationCenter.default.addObserver(forName: ChitgramTabs.extraButtonPressedNotification, object: nil, queue: .main, using: { [weak self] _ in
                self?.chitgramExtraPressed()
            })
        }
        self.chitgramShowCallsTab = showCallsTab
        self.chitgramShowNewsTab = showNewsTab
        if self.chitgramTabsObserver == nil {
            self.chitgramTabsObserver = NotificationCenter.default.addObserver(forName: ChitgramTabs.didChangeNotification, object: nil, queue: .main, using: { [weak self] _ in
                guard let self else {
                    return
                }
                self.updateRootControllers(showCallsTab: self.chitgramShowCallsTab, showNewsTab: self.chitgramShowNewsTab)
            })
        }
    }
}
