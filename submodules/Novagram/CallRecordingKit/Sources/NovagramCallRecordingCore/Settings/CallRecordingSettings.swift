// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// What a recording keeps of the call's video. Stored by its raw value under ``CallRecordingSettings/videoQualityKey``.
public enum CallRecordingVideoQuality: String, CaseIterable, Sendable {
    /// Only the voices: the host pushes no video, and the file is audio (`.m4a`) even in a video call.
    case audioOnly = "audio"
    /// Video at 15 frames per second and half the bit rate (``CallRecordingConfiguration/init(quality:)``).
    case batterySaver = "saver"
    /// Video at 30 frames per second.
    case high = "high"

    /// The quality while nothing is stored: a recording keeps the call, smooth video is not the point.
    public static let `default`: CallRecordingVideoQuality = .batterySaver

    /// Whether the host pushes the call's video into the session at all.
    public var recordsVideo: Bool {
        return self != .audioOnly
    }
}

/// The call recording settings, shared by both apps: same keys, in the `pro_messager` suite. The switches default
/// off; the video quality defaults to ``CallRecordingVideoQuality/default``.
///
/// Each switch is the feature itself: there is no second gate. Where an app shows the switches (a Developer section
/// while the feature is unapproved, its normal section once approved) is the app's business.
public struct CallRecordingSettings {
    /// The `UserDefaults` suite both apps use for Novagram settings.
    public static let suiteName = "pro_messager"
    /// The "Call recording" switch.
    public static let enabledKey = "novagram_call_recording"
    /// The "Record every call automatically" switch.
    public static let autoKey = "novagram_call_recording_auto"
    /// Set once the first-recording consent alert was accepted.
    public static let warnedKey = "novagram_call_recording_warned"
    /// The video quality of new recordings (``CallRecordingVideoQuality`` raw value).
    public static let videoQualityKey = "novagram_call_recording_video_quality"

    /// Posted by an app when a call changes a switch or saves a recording, so open settings screens refresh.
    public static let changedNotification = Notification.Name("NovagramCallRecordingChanged")

    public let defaults: UserDefaults

    /// Reads and writes `defaults`; tests inject their own suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The `pro_messager` suite (the standard defaults if the suite cannot be opened).
    public init() {
        self.init(defaults: UserDefaults(suiteName: CallRecordingSettings.suiteName) ?? .standard)
    }

    /// "Call recording": calls show the Record control. Missing key = off.
    public var isEnabled: Bool {
        get {
            return self.defaults.bool(forKey: CallRecordingSettings.enabledKey)
        }
        nonmutating set {
            self.defaults.set(newValue, forKey: CallRecordingSettings.enabledKey)
        }
    }

    /// "Record every call automatically". Only takes effect while ``isEnabled``. Missing key = off.
    public var isAutoEnabled: Bool {
        get {
            return self.defaults.bool(forKey: CallRecordingSettings.autoKey)
        }
        nonmutating set {
            self.defaults.set(newValue, forKey: CallRecordingSettings.autoKey)
        }
    }

    /// The video quality of the next recording; a running recording keeps the one it started with. A missing or
    /// unknown value reads as ``CallRecordingVideoQuality/default``.
    public var videoQuality: CallRecordingVideoQuality {
        get {
            return self.defaults.string(forKey: CallRecordingSettings.videoQualityKey).flatMap(CallRecordingVideoQuality.init(rawValue:)) ?? .default
        }
        nonmutating set {
            self.defaults.set(newValue.rawValue, forKey: CallRecordingSettings.videoQualityKey)
        }
    }

    /// The consent alert was accepted once.
    public var wasWarned: Bool {
        get {
            return self.defaults.bool(forKey: CallRecordingSettings.warnedKey)
        }
        nonmutating set {
            self.defaults.set(newValue, forKey: CallRecordingSettings.warnedKey)
        }
    }
}
