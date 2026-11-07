// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A Novagram feature whose successful use counts toward the rating prompt.
///
/// The raw values are stored on the device and shared by both apps. Never rename or reuse one: a renamed value drops
/// the user's counts. Add new features as new cases. Each app reports only the features it has.
public enum ReviewPromptFeature: String, CaseIterable, Codable, Sendable {
    /// The edited history of a message was opened.
    case editedHistory
    /// One message was translated.
    case translateMessage
    /// A chat was translated automatically. Not counted by default: it runs on every sent message.
    case autoTranslate
    /// A voice or round message was turned into text.
    case speechToText
    /// A voice message was translated.
    case voiceTranslate
    /// A story was saved.
    case storySave
    /// A round video was sent from a gallery video.
    case roundVideoFromGallery
    /// Messages were forwarded without the sender names.
    case forwardWithoutNames
    /// Ghost mode was used.
    case ghostMode
    /// A locked chat was unlocked.
    case chatLockUnlock
    /// The secret vault was unlocked.
    case secretVaultUnlock
    /// A call recording was saved. Not counted by default: the feature is unapproved and hidden.
    case callRecordingSaved
    /// "View First Message" jumped to the start of a chat.
    case viewFirstMessage
}
