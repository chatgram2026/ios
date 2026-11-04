import Foundation

/// Points Chitgram's stores at the app group, so the app and its extensions share them. Called once at launch,
/// before anything reads a switch.
public func chitgramConfigure(appGroupName: String) {
    ChitgramPreferences.shared.configure(appGroupName: appGroupName)

    let fileManager = FileManager.default
    let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)
        ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let directory = base.appendingPathComponent("chitgram", isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    ChitgramEditHistory.shared.configure(directory: directory)
}
