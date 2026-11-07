// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import NovagramCallRecordingCore

/// The default formatting. The iOS app replaces it with Telegram's own (date headers, 12/24-hour time, sizes).
@available(macOS 14, iOS 15, *)
public enum CallRecordingFormatters {
    /// m:ss, or h:mm:ss from one hour.
    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, rest)
        }
        return String(format: "%d:%02d", minutes, rest)
    }

    /// "512 B", "742,3 KB", "2,6 MB", "1,2 GB" (1024-based, one decimal, like Telegram).
    public static func size(_ bytes: Int64, decimalSeparator: String = Locale.current.decimalSeparator ?? ".") -> String {
        guard bytes >= 1024 else {
            return "\(max(bytes, 0)) B"
        }
        let units = ["KB", "MB", "GB"]
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let tenths = Int((value * 10).rounded())
        return "\(tenths / 10)\(decimalSeparator)\(tenths % 10) \(units[unit])"
    }

    /// Today / Yesterday / "October 27" / "October 27, 2025", in `language`.
    public static func dayHeader(_ day: Date, strings: CallRecordingStrings, calendar: Calendar = .current, now: Date = Date()) -> String {
        if calendar.isDate(day, inSameDayAs: now) {
            return strings.today
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return strings.yesterday
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: strings.language.rawValue)
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMMd" : "yMMMMd")
        return formatter.string(from: day)
    }

    /// "40 seconds", for VoiceOver.
    public static func spokenDuration(_ seconds: Double, language: CallRecordingLanguage) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: language.rawValue)
        formatter.calendar = calendar
        return formatter.string(from: max(0, seconds.rounded())) ?? CallRecordingFormatters.duration(seconds)
    }
}
