// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreGraphics
import NovagramCallRecordingCore

/// Everything the host injects into ``CallRecordingsListView``.
@available(macOS 14, iOS 15, *)
public struct CallRecordingUIEnvironment {
    public var theme: CallRecordingTheme
    public var strings: CallRecordingStrings
    /// The "Call recording" switch is on; picks the empty-state text.
    public var isRecordingEnabled: Bool
    /// A day section's title. The default uses ``CallRecordingStrings/today`` and ``CallRecordingStrings/yesterday``
    /// as they were when the environment was made.
    public var dayHeader: (Date) -> String
    /// A file size.
    public var sizeString: (Int64) -> String
    /// The time on the right of a row.
    public var timeString: (Date) -> String
    /// The duration in a row's subtitle.
    public var durationString: (Double) -> String
    /// The duration for VoiceOver.
    public var spokenDuration: (Double) -> String
    /// A row was tapped (or Play chosen): open the file with QuickLook or the app's own player.
    public var onPlay: @MainActor (CallRecording) -> Void
    /// Share was chosen for these files. The rect is the row or button it came from, in the window's coordinates
    /// (SwiftUI's global space), to anchor a popover; `.zero` when unknown.
    public var onShare: @MainActor ([URL], CGRect) -> Void
    /// The list puts its title, menu and select-mode buttons into the navigation container's toolbar. Turn it off
    /// when the host draws its own navigation bar (the iOS app's Telegram bar) and drives
    /// ``CallRecordingsListViewModel`` instead; the select-mode Share / Delete bar at the bottom stays.
    public var showsToolbar: Bool = true
    /// The select-mode Share / Delete bar at the bottom (iOS). Turn it off when the host draws its own bar (the iOS
    /// app's Telegram toolbar) and drives the selection through ``CallRecordingsListViewModel``: Share with
    /// ``CallRecordingsListViewModel/selectedURLs``, Delete with ``CallRecordingsListViewModel/requestDeleteSelected()``.
    public var showsSelectionBar: Bool = true
    /// Asks the user before files are deleted (one row, the selection, Clear All). Gets the question and a closure
    /// that deletes; call it only when the user confirms. When nil the list shows its own SwiftUI alert.
    public var confirmDeletion: (@MainActor (_ text: String, _ confirm: @escaping @MainActor () -> Void) -> Void)?

    public init(
        languageCode: String = "en",
        theme: CallRecordingTheme = .system,
        isRecordingEnabled: Bool = true,
        onPlay: @escaping @MainActor (CallRecording) -> Void,
        onShare: @escaping @MainActor ([URL], CGRect) -> Void
    ) {
        let strings = CallRecordingStrings(languageCode: languageCode)
        self.theme = theme
        self.strings = strings
        self.isRecordingEnabled = isRecordingEnabled
        self.dayHeader = { day in
            CallRecordingFormatters.dayHeader(day, strings: strings)
        }
        self.sizeString = { bytes in
            CallRecordingFormatters.size(bytes)
        }
        let timeFormatter = DateFormatter()
        timeFormatter.setLocalizedDateFormatFromTemplate("jmm")
        self.timeString = { date in
            timeFormatter.string(from: date)
        }
        self.durationString = CallRecordingFormatters.duration
        let language = strings.language
        self.spokenDuration = { seconds in
            CallRecordingFormatters.spokenDuration(seconds, language: language)
        }
        self.onPlay = onPlay
        self.onShare = onShare
    }
}
