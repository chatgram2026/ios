import Foundation
import SwiftSignalKit

public extension ChitgramPreferences {
    /// The switch's value now and after every change, so a screen that is already open follows a change made in
    /// the Chitgram settings at once.
    func boolSignal(_ key: Key) -> Signal<Bool, NoError> {
        return Signal { subscriber in
            subscriber.putNext(self.bool(key))
            // Strong: the store is a process-wide singleton, and the observer goes with the subscription.
            let observer = NotificationCenter.default.addObserver(forName: ChitgramPreferences.didChangeNotification, object: self, queue: nil, using: { notification in
                guard (notification.userInfo?["key"] as? String) == key.rawValue else {
                    return
                }
                subscriber.putNext(self.bool(key))
            })
            return ActionDisposable {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        |> distinctUntilChanged
    }

    /// Fires once at once and again after any switch changes; for screens that show many of them.
    var changes: Signal<Void, NoError> {
        return Signal { subscriber in
            subscriber.putNext(Void())
            let observer = NotificationCenter.default.addObserver(forName: ChitgramPreferences.didChangeNotification, object: self, queue: nil, using: { _ in
                subscriber.putNext(Void())
            })
            return ActionDisposable {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
