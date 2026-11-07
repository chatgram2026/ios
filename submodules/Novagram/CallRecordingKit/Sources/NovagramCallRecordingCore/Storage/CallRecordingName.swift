// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Reads the peer's name back from a recording's file name ("Name yyyy-MM-dd HH.mm" plus an optional " 2" / " 3"
/// de-dup suffix, see ``CallRecordingStorage/fileName(peerName:date:isVideo:)``) and makes the avatar initials.
public enum CallRecordingName {
    private static let stampPattern = " [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}\\.[0-9]{2}( [0-9]+)?$"
    private static let maxInitials = 2

    /// "Jasur Karimov 2026-10-30 14.25 2" -> "Jasur Karimov". A name without the date stamp comes back unchanged.
    /// Pass the file name without its extension.
    public static func peerName(fromFileName fileName: String) -> String {
        guard let range = fileName.range(of: CallRecordingName.stampPattern, options: .regularExpression) else {
            return fileName
        }
        let name = String(fileName[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? fileName : name
    }

    /// "Jasur Karimov Group" -> "JK", "Ali" -> "A".
    public static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        let letters = words.prefix(CallRecordingName.maxInitials).compactMap { $0.first }
        return String(letters).uppercased()
    }

    /// A stable index for the avatar gradient: the same name always gets the same colour, on every launch
    /// (`hashValue` is seeded per process, so it cannot be used).
    public static func colorIndex(of name: String, count: Int) -> Int {
        guard count > 0 else {
            return 0
        }
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return sum % count
    }
}
