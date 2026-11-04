import Foundation
import UserNotifications
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChitgramCore

/// Chitgram unread message reminder (Android `MessageReminder`): when an incoming message stays unread for the
/// chosen number of minutes, one notification says so ("Unread messages"). Reading everything cancels it, and there
/// is only ever one pending per account, however many messages arrive.
///
/// A local notification, so it fires even when iOS has suspended the app.
final class ChitgramMessageReminder {
    private weak var context: AccountContext?
    private let identifier: String
    private var incomingDisposable: Disposable?
    private var unreadDisposable: Disposable?
    private var switchDisposable: Disposable?

    init(context: AccountContext) {
        self.context = context
        self.identifier = "chitgram.reminder.\(context.account.peerId.toInt64())"
        let accountPeerId = context.account.peerId

        self.incomingDisposable = (context.account.stateManager.chitgramIncomingMessages
        |> deliverOnMainQueue).startStrict(next: { [weak self] messages in
            guard let self, ChitgramPreferences.shared.bool(.reminderEnabled) else {
                return
            }
            if messages.contains(where: { $0.flags.contains(.Incoming) && $0.id.peerId != accountPeerId }) {
                self.schedule()
            }
        })

        // Everything read: nothing to remind about.
        self.unreadDisposable = (context.engine.data.subscribe(TelegramEngine.EngineData.Item.Messages.TotalReadCounters())
        |> map { counters -> Bool in
            return counters.count(for: .raw, in: .chats, with: .all) == 0
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue).startStrict(next: { [weak self] allRead in
            if allRead {
                self?.cancel()
            }
        })

        // Turning the reminder off drops a pending one.
        self.switchDisposable = (ChitgramPreferences.shared.boolSignal(.reminderEnabled)
        |> deliverOnMainQueue).startStrict(next: { [weak self] enabled in
            if !enabled {
                self?.cancel()
            }
        })
    }

    deinit {
        self.incomingDisposable?.dispose()
        self.unreadDisposable?.dispose()
        self.switchDisposable?.dispose()
    }

    private func schedule() {
        let identifier = self.identifier
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests(completionHandler: { requests in
            // One reminder at a time: a later message does not push the first one back.
            if requests.contains(where: { $0.identifier == identifier }) {
                return
            }
            let minutes = max(1, min(59, ChitgramPreferences.shared.int(.reminderDelayMin)))
            let content = UNMutableNotificationContent()
            content.title = ChitgramStrings.get(277)
            content.body = ChitgramStrings.get(278)
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(minutes * 60), repeats: false)
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger), withCompletionHandler: nil)
        })
    }

    private func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [self.identifier])
    }
}
