import Foundation
import SwiftSignalKit

/// Ghost mode (Android `GhostVariable`): one master switch that hides everything, and four switches that each hide
/// one signal. A signal is hidden when the master switch is on **or** its own switch is.
public extension ChitgramPreferences {
    /// Stories are watched without telling the author when the story switch or the ghost-mode master switch is on
    /// (Android: `StoriesController`, `GhostStory || GhostVariable.ghostMode`). The story still turns grey on this
    /// device; only the requests that reach the author are left out.
    var hidesStoryViews: Bool {
        return self.bool(.ghostStory) || self.bool(.ghost)
    }

    /// No `readHistory`: the other side never sees the second tick. The chat is still read on this device.
    var hidesReadReceipts: Bool {
        return self.bool(.ghost) || self.bool(.ghostHideRead)
    }

    /// The account stays offline to others.
    var hidesOnline: Bool {
        return self.bool(.ghost) || self.bool(.ghostHideOnline)
    }

    /// No "typing…".
    var hidesTyping: Bool {
        return self.bool(.ghost) || self.bool(.ghostHideTyping)
    }

    /// No "sending photo…", "recording voice…" and the like.
    var hidesUploadActivity: Bool {
        return self.bool(.ghost) || self.bool(.ghostHideUpload)
    }

    func hidesReadReceiptsSignal() -> Signal<Bool, NoError> {
        return combineLatest(self.boolSignal(.ghost), self.boolSignal(.ghostHideRead))
        |> map { master, own -> Bool in
            return master || own
        }
        |> distinctUntilChanged
    }

    func hidesOnlineSignal() -> Signal<Bool, NoError> {
        return combineLatest(self.boolSignal(.ghost), self.boolSignal(.ghostHideOnline))
        |> map { master, own -> Bool in
            return master || own
        }
        |> distinctUntilChanged
    }
}
