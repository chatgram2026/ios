// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The "I'm recording this call" chat message: when to send it, and its text.
///
/// A recording is never secret. When one starts, the app sends the notice to the call's chat, at most once per call
/// session id:
/// - manual and automatic starts are treated the same;
/// - only once the recorder has really started (a start that failed sends nothing);
/// - only in a call with one user (1:1); group calls and bots never get it;
/// - a Stop and a new Record in the same call send nothing more while the notice is on its way or delivered;
/// - a notice that failed (the app then stops and throws the recording away) lets the next Record send it again;
/// - a new call has a new session id, so it gets its own notice.
///
/// A value type with no threading of its own: keep it on one thread (the apps use the main thread).
public struct CallRecordingNoticePolicy: Sendable {
    public enum Status: Sendable, Equatable {
        case sending
        case delivered
        case failed
    }

    private var statuses: [UUID: Status] = [:]

    public init() {
    }

    public func status(callSessionId: UUID) -> Status? {
        return self.statuses[callSessionId]
    }

    /// True when the notice must be sent now for this recording start, and marks it as on its way.
    /// - Parameters:
    ///   - isOneToOneUser: the call is a private call with a user (not a group call, not a bot).
    ///   - recorderDidStart: the recorder started; pass false when ``CallRecordingCenter/start(callId:peerName:configuration:onDetach:)`` threw.
    public mutating func beginSending(callSessionId: UUID, isOneToOneUser: Bool, recorderDidStart: Bool) -> Bool {
        guard isOneToOneUser, recorderDidStart else {
            return false
        }
        switch self.statuses[callSessionId] {
        case .sending, .delivered:
            return false
        case .failed, nil:
            self.statuses[callSessionId] = .sending
            return true
        }
    }

    public mutating func markDelivered(callSessionId: UUID) {
        self.statuses[callSessionId] = .delivered
    }

    public mutating func markFailed(callSessionId: UUID) {
        self.statuses[callSessionId] = .failed
    }

    /// The call is over: nothing can be recorded in it any more.
    public mutating func forget(callSessionId: UUID) {
        self.statuses.removeValue(forKey: callSessionId)
    }

    /// The chat message, in the app's language (English for any language without its own text).
    public static func message(languageCode: String) -> String {
        return CallRecordingLanguage(code: languageCode).pick(
            en: "🔴 I'm recording this call (Chitgram)",
            uz: "🔴 Men bu qo'ng'iroqni yozib olyapman (Chitgram)",
            ru: "🔴 Я записываю этот звонок (Chitgram)",
            zh: "🔴 我正在录制这次通话（Chitgram）"
        )
    }

    /// The toast shown when the notice could not be sent (the recording is then stopped and thrown away).
    public static func failureMessage(languageCode: String) -> String {
        return CallRecordingLanguage(code: languageCode).pick(
            en: "Couldn't notify the other person, so the call is not being recorded.",
            uz: "Suhbatdoshga xabar berib bo'lmadi, shuning uchun qo'ng'iroq yozilmayapti.",
            ru: "Не удалось уведомить собеседника, поэтому звонок не записывается.",
            zh: "无法通知对方，因此本次通话未被录制。"
        )
    }
}
