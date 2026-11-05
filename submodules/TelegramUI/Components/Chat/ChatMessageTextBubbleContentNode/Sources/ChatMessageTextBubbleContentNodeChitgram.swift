import Foundation
import TelegramCore
import ChitgramCore

/// Chitgram (Android `EditPreview`): an edited message shows what it used to say, right in the bubble — each earlier
/// version above the text as a struck-through quote, and a line under it saying how many were kept. Only the text
/// the bubble lays out changes; the stored message, the chat list, notifications and forwards are untouched.
func chitgramDecorateEdited(text: String, entities: [MessageTextEntity], accountPeerId: EnginePeer.Id, messageId: EngineMessage.Id) -> (text: String, entities: [MessageTextEntity])? {
    if !ChitgramPreferences.shared.bool(.saveEdited) {
        return nil
    }
    let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var versions: [String] = []
    for version in ChitgramEditHistory.shared.versions(ChitgramEditHistory.MessageKey(accountPeerId: accountPeerId, messageId: messageId)) {
        let value = version.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A version that reads the same as the text now, or as the one before it, says nothing.
        if value.isEmpty || value == current || value == versions.last {
            continue
        }
        versions.append(value)
    }
    if versions.isEmpty {
        return nil
    }

    let label = ChitgramStrings.get(553)
    var prefix = ""
    var resultEntities: [MessageTextEntity] = []
    // At most the three newest versions, in the order they happened; long ones are cut (the menu has them whole).
    for version in versions.suffix(3) {
        let shown = version.count > 160 ? String(version.prefix(160)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : version
        let start = (prefix as NSString).length
        let line = label + " " + shown
        let lineLength = (line as NSString).length
        prefix += line + "\n"
        resultEntities.append(MessageTextEntity(range: start ..< start + lineLength, type: .BlockQuote(isCollapsed: false)))
        let textStart = start + (label as NSString).length + 1
        resultEntities.append(MessageTextEntity(range: textStart ..< start + lineLength, type: .Strikethrough))
    }
    let offset = (prefix as NSString).length
    for entity in entities {
        resultEntities.append(MessageTextEntity(range: (entity.range.lowerBound + offset) ..< (entity.range.upperBound + offset), type: entity.type))
    }
    let footer = ChitgramStrings.format(versions.count == 1 ? 554 : 555, versions.count)
    let footerStart = offset + (text as NSString).length + 1
    resultEntities.append(MessageTextEntity(range: footerStart ..< footerStart + (footer as NSString).length, type: .Italic))
    return (prefix + text + "\n" + footer, resultEntities)
}
