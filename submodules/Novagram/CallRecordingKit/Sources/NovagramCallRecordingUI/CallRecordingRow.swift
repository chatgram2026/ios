// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import NovagramCallRecordingCore

// One row, laid out like a row of Telegram's call log: an avatar with the peer's initials, the name over
// "Video call · 0:40 · 742,3 KB", and the time on the right. At accessibility text sizes the time moves under the
// subtitle and the name may wrap.
@available(macOS 14, iOS 15, *)
struct CallRecordingRow: View {
    static let avatarSize: CGFloat = 40
    static let minHeight: CGFloat = 44
    static let textSpacing: CGFloat = 12

    let recording: CallRecording
    let environment: CallRecordingUIEnvironment
    let fontScale: CGFloat
    let isLarge: Bool
    let frames: CallRecordingFrameStore

    var body: some View {
        let theme = self.environment.theme
        let name = self.recording.peerName
        let time = self.environment.timeString(self.recording.date)
        let subtitle = CallRecordingsListModel.subtitle(for: self.recording, strings: self.environment.strings, durationString: self.environment.durationString, sizeString: self.environment.sizeString)
        let timeFont = Font.system(size: theme.timeFontSize * self.fontScale).monospacedDigit()
        HStack(alignment: self.isLarge ? .top : .center, spacing: CallRecordingRow.textSpacing) {
            CallRecordingAvatar(name: name, gradients: theme.avatarGradients)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name)
                        .font(.system(size: theme.titleFontSize * self.fontScale, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(self.isLarge ? nil : 1)
                    Spacer(minLength: 0)
                    if !self.isLarge {
                        Text(time)
                            .font(timeFont)
                            .foregroundColor(theme.secondaryText)
                            .fixedSize()
                    }
                }
                Text(subtitle)
                    .font(.system(size: theme.subtitleFontSize * self.fontScale))
                    .foregroundColor(theme.secondaryText)
                if self.isLarge {
                    Text(time)
                        .font(timeFont)
                        .foregroundColor(theme.secondaryText)
                }
            }
        }
        .frame(minHeight: CallRecordingRow.minHeight)
        .contentShape(Rectangle())
        .background(GeometryReader { proxy in
            // Remembers where the row is, for the share popover; no state change, so no extra render.
            let _ = self.frames.record(self.recording.url, frame: proxy.frame(in: .global))
            Color.clear
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(self.accessibilityText(name: name, time: time)))
        .accessibilityAddTraits(.isButton)
    }

    private func accessibilityText(name: String, time: String) -> String {
        let strings = self.environment.strings
        let kind = self.recording.isVideo ? strings.videoCall : strings.voiceCall
        let duration = self.environment.spokenDuration(self.recording.duration)
        let size = self.environment.sizeString(self.recording.size)
        return "\(name), \(kind), \(duration), \(size), \(time)"
    }
}

@available(macOS 14, iOS 15, *)
struct CallRecordingAvatar: View {
    let name: String
    let gradients: [[Color]]

    var body: some View {
        let colors = self.gradients.isEmpty ? [Color.gray] : self.gradients[CallRecordingName.colorIndex(of: self.name, count: self.gradients.count)]
        Circle()
            .fill(LinearGradient(gradient: Gradient(colors: colors), startPoint: .top, endPoint: .bottom))
            .frame(width: CallRecordingRow.avatarSize, height: CallRecordingRow.avatarSize)
            .overlay(
                Text(CallRecordingName.initials(of: self.name))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            )
            .accessibilityHidden(true)
    }
}

// Where each row and the bottom Share button were last laid out, in global coordinates. A plain reference, written
// during layout, so scrolling never triggers a state update.
@available(macOS 14, iOS 15, *)
@MainActor
final class CallRecordingFrameStore {
    private var frames: [URL: CGRect] = [:]
    var shareButtonFrame: CGRect = .zero

    func record(_ url: URL, frame: CGRect) {
        self.frames[url] = frame
    }

    func frame(for urls: [URL]) -> CGRect {
        guard let first = urls.first else {
            return .zero
        }
        return self.frames[first] ?? .zero
    }

    func forget(_ urls: [URL]) {
        for url in urls {
            self.frames[url] = nil
        }
    }
}
