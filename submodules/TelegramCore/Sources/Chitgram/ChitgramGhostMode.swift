import Foundation
import SwiftSignalKit
import ChitgramCore

/// Chitgram ghost mode, read receipts: completes at once while they are shown; while ghost mode hides them it waits,
/// and completes when it stops hiding them.
///
/// The chat is read on this device as usual; only the push to the server (`readHistory`, which is what gives the
/// other side its second tick) waits here. Telegram's read-state sync keeps the operation in place meanwhile, so
/// leaving ghost mode sends the latest read state of every chat read in it (Android `flushGhostReads`), and the
/// server keeps treating those messages as unread without them coming back here: a local read mark ahead of the
/// server's is kept by both the state replay and the read-state validation.
/// Chitgram ghost mode, chat actions: whether this `messages.setTyping` must not be sent. The groups are Android's
/// (`GhostVariable.blocksAction`): typing, recording a voice or round video and picking a sticker follow the typing
/// switch; uploads follow the upload switch; anything else only the master switch. A cancel is never held back,
/// since it clears a status the other side may already show — callers pass `nil` for it and do not ask.
func chitgramHidesInputActivity(_ activity: PeerInputActivity) -> Bool {
    let preferences = ChitgramPreferences.shared
    switch activity {
    case .typingText, .recordingVoice, .recordingInstantVideo, .choosingSticker:
        return preferences.hidesTyping
    case .uploadingFile, .uploadingPhoto, .uploadingVideo, .uploadingInstantVideo:
        return preferences.hidesUploadActivity
    case .playingGame, .speakingInGroupCall, .interactingWithEmoji, .seeingEmojiInteraction:
        return preferences.bool(.ghost)
    }
}

func chitgramReadReceiptsGate<E>() -> Signal<Never, E> {
    return ChitgramPreferences.shared.hidesReadReceiptsSignal()
    |> filter { hides in
        return !hides
    }
    |> take(1)
    |> ignoreValues
    |> castError(E.self)
}
