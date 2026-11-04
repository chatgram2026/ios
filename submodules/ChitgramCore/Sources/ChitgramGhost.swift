import Foundation

public extension ChitgramPreferences {
    /// Stories are watched without telling the author when the story switch or the ghost-mode master switch is on
    /// (Android: `StoriesController`, `GhostStory || GhostVariable.ghostMode`). The story still turns grey on this
    /// device; only the requests that reach the author are left out.
    var hidesStoryViews: Bool {
        return self.bool(.ghostStory) || self.bool(.ghost)
    }
}
