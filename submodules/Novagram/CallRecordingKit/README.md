# NovagramCallRecordingKit

The call recording SDK shared by the Novagram iOS app (Bazel) and the Novagram macOS app (SwiftPM). It records a
1:1 call into one file on the device: both voices mixed into one AAC track, and the video of both sides composed
into one H.264 track when either side ever had video. It also holds the recordings folder, the shared settings
keys, the "I'm recording this call" notice rule and a lightweight SwiftUI recordings list.

Foundation, AVFoundation, Core Image, Core Video, Metal, Accelerate, Combine and SwiftUI only. No Telegram module
(SwiftSignalKit, TelegramVoip, Postbox, Display, AccountContext) and no third-party dependency: each app writes a
thin adapter from its own call types to the neutral API below.

## License

GPL-2.0-or-later. `LICENSE` holds the GPL version 2 text; every source file starts with
`// SPDX-License-Identifier: GPL-2.0-or-later`.

## Products

| Product / Bazel target      | Contents                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NovagramCallRecordingCore` | `CallRecordingCenter` (per-call sessions and state), the audio tap and its real-time ring, the mixer (downmix, resample to 48 kHz, mute), the recorder (AVAssetWriter, one timeline, 2 s movie fragments, B-frames off, black frames until the first real video frame, `.m4a` passthrough export when no video ever came), the video frame conversion (pixel buffer / NV12 / I420, rotation and mirroring), the compositor (default 720x1280, the big side aspect-fit, the small one as a rounded picture-in-picture in a corner, swap), the storage (folder, file names, list, delete, recovery of recordings a killed app left in `.partial`), `CallRecordingSettings`, `CallRecordingSettingsStrings` (the settings page texts) and `CallRecordingNoticePolicy`. |
| `NovagramCallRecordingUI`   | `CallRecordingsListView` (SwiftUI, iOS 15+, macOS 14+): the summary line, day sections, rows with an initials avatar, the storage footer, the empty state, a menu with Filter All/Video/Voice, Select (multi-select, then Share and Delete N) and Clear All with confirmations. On the Mac it is a native `List` with multi-selection, a context menu, double-click to play and the Delete key.                                                                                                                                                                                                                                                                                                           |

Platforms: iOS 15, macOS 10.13 (the package minimum, so a host that deploys to 10.13 can depend on it). Every recorder,
audio, video, UI and list type is `@available(macOS 14, iOS 15, *)`; on the Mac the host wraps all use in
`if #available(macOS 14, *)`. Only the plain Foundation pieces have no gate: `CallRecording`, `CallRecordingStorage`,
`CallRecordingName`, `CallRecordingSettings`, `CallRecordingSettingsStrings`, `CallRecordingLanguage`, `CallRecordingNoticePolicy`,
`CallRecordingConfiguration`, `CallRecordingError`, `CallRecordingState`, `CallRecordingAudioSource`,
`CallRecordingVideoSide`, `CallRecordingPipCorner` and `CallRecordingVideoLayout`. Swift 6 language mode in SwiftPM. The sources also build in Swift 5 mode with
`-warnings-as-errors` (checked), so the Bazel targets work in either language mode.

## Integration

Both apps add this repository as a git submodule pinned by commit (no tags) and update it by moving the pin.

**iOS (Bazel).** Add the submodule at `submodules/Novagram/CallRecordingKit`; its root `BUILD` exposes
`//submodules/Novagram/CallRecordingKit:NovagramCallRecordingCore` and `:NovagramCallRecordingUI` (the same pattern
as the search SDK's `//submodules/Novagram/SearchKit:NovagramSearchKit`).

**macOS (SwiftPM).** Add the submodule and reference it as a local package
(`.package(path: "../novagram-call-recording-kit")`), then depend on the `NovagramCallRecordingCore` and
`NovagramCallRecordingUI` products.

### iOS adapters

```swift
// One center per app. The default folder is Application Support/CallRecordings, the iOS app's current one.
let center = CallRecordingCenter(storage: .default)

// Start: the session is where the call pushes audio and video. onDetach runs once, when the recording stops
// (Stop, stopAll, or the writer failing on its own): remove the tap and the video subscriptions there.
let session = try center.start(callId: call.internalId, peerName: peerName, onDetach: {
    audioDevice.setAudioTap(nil)
    disposables.dispose()
})

// The ADM tap runs on the real-time audio thread; appendPCM only copies into a preallocated ring.
let tap = session.audioTap
audioDevice.setAudioTap { samples, frames, channels, sampleRate, isPlayout in
    tap.appendPCM(samples, frames: frames, channels: channels, sampleRate: sampleRate, isPlayout: isPlayout)
}

// Video: map VideoFrameData to CallRecordingVideoFrame, with the call screen's orientation rule.
disposables.add(incomingVideo.start(next: { data in
    session.appendVideoFrame(CallRecordingVideoFrame(telegram: data), side: .remote)
}))
disposables.add(outgoingVideo.start(next: { data in
    session.appendVideoFrame(CallRecordingVideoFrame(telegram: data), side: .local)
}))
disposables.add(isMutedSignal.start(next: { session.setMuted($0) }))

// The call screen reports where its small picture is and whether the videos are swapped.
center.setLayout(callId: call.internalId, pipCorner: .bottomLeft, isSwapped: true)

// Stop, and the termination path.
center.stop(callId: call.internalId) { result in /* toast with the file, or the error */ }
center.stopAll(timeout: 2) { semaphore.signal() }
```

The frame adapter stays in the app, because it reads Telegram's types. It is the old
`NovagramCallVideoFrame.init(_ data:)` with the new output type:

```swift
extension CallRecordingVideoFrame {
    init(telegram data: OngoingGroupCallContext.VideoFrameData) {
        let buffer: CallRecordingVideoFrame.Buffer
        switch data.buffer {
        case let .native(native), let .argb(native), let .bgra(native):
            buffer = .pixelBuffer(native.pixelBuffer)
        case let .nv12(nv12):
            buffer = .nv12(y: nv12.y, strideY: nv12.strideY, uv: nv12.uv, strideUV: nv12.strideUV, width: nv12.width, height: nv12.height)
        case let .i420(i420):
            buffer = .i420(y: i420.y, strideY: i420.strideY, u: i420.u, strideU: i420.strideU, v: i420.v, strideV: i420.strideV, width: i420.width, height: i420.height)
        }
        // Same rotation and mirroring as AdaptedCallVideoSource for a portrait screen held in portrait.
        let orientation = data.deviceRelativeOrientation ?? data.orientation
        var mirrorHorizontally = data.mirrorHorizontally
        var mirrorVertically = data.mirrorVertically
        if let relative = data.deviceRelativeOrientation, relative != data.orientation {
            let shouldMirror = data.mirrorHorizontally || data.mirrorVertically
            switch relative {
            case .rotation0, .rotation180:
                mirrorHorizontally = shouldMirror
                mirrorVertically = false
            case .rotation90, .rotation270:
                mirrorHorizontally = false
                mirrorVertically = shouldMirror
            }
        }
        let turns: Int
        switch orientation {
        case .rotation0: turns = 0
        case .rotation90: turns = 1
        case .rotation180: turns = 2
        case .rotation270: turns = 3
        }
        self.init(buffer: buffer, rotationQuarterTurns: turns, mirrorHorizontally: mirrorHorizontally, mirrorVertically: mirrorVertically)
    }
}
```

State for the REC mm:ss timer: `center.stateUpdates(callId:)` (an `AsyncStream`) or Combine on
`center.$recordingStartDates`; wrap either in a Signal where the call screen needs one.

The recordings screen: host `CallRecordingsListView` in a `UIHostingController` and map Telegram's presentation
data into the environment:

```swift
var environment = CallRecordingUIEnvironment(
    languageCode: languageCode,
    theme: CallRecordingTheme(
        background: Color(theme.list.blocksBackgroundColor),
        card: Color(theme.list.itemBlocksBackgroundColor),
        primaryText: Color(theme.list.itemPrimaryTextColor),
        secondaryText: Color(theme.list.itemSecondaryTextColor),
        accent: Color(theme.list.itemAccentColor),
        destructive: Color(theme.list.itemDestructiveColor),
        separator: Color(theme.list.itemBlocksSeparatorColor),
        avatarGradients: AvatarNode.gradientColors.map { $0.map(Color.init) },
        titleFontSize: listsFontSize, subtitleFontSize: floor(listsFontSize * 14 / 17),
        timeFontSize: floor(listsFontSize * 15 / 17), freeTextFontSize: floor(listsFontSize * 13 / 17),
        followsDynamicType: false,
        freeText: Color(theme.list.freeTextColor),
        listSideInset: 20
    ),
    isRecordingEnabled: CallRecordingSettings().isEnabled,
    onPlay: { recording in /* QuickLook or Telegram's player */ },
    onShare: { urls, rect in /* UIActivityViewController, popover anchored at rect */ }
)
environment.dayHeader = { day in /* Weekday_Today / Weekday_Yesterday / Date_ChatDateHeader */ }
environment.sizeString = { dataSizeString($0, formatting: DataSizeStringFormatting(presentationData: presentationData)) }
environment.timeString = { /* stringForShortTimestamp with dateTimeFormat */ }
environment.strings.cancel = strings.Common_Cancel
```

The view puts its title, menu and select-mode buttons into the navigation container's toolbar. Telegram's
`ViewController` draws its own navigation bar, so the iOS app sets `environment.showsToolbar = false`, keeps one
`CallRecordingsListViewModel` and drives it from its own bar buttons: `filter`, `setSelecting(_:)`,
`toggleSelectAll()`, `allVisibleSelected`, `requestClearAll()` (the list shows the same confirmation as its own
menu). The app also draws Telegram's own select-mode toolbar and alerts: `environment.showsSelectionBar = false`
(Share with `selectedURLs`, Delete with `requestDeleteSelected()`; give the hosting controller
`additionalSafeAreaInsets.bottom` = toolbar height + home indicator so the rows scroll above it) and
`environment.confirmDeletion = { text, confirm in /* textAlertController, then confirm() */ }`, used for one row, the
selection and Clear All. `listSideInset` sets the cards' side margin with `contentMargins` on iOS 17+; on iOS 15-16 the
host widens `additionalSafeAreaInsets.left/right` by the difference from 16. On iOS 15 the List's own background is not
hidable from SwiftUI: clear `UITableView`/`UICollectionView` through `appearance(whenContainedInInstancesOf:)` with a
`UIHostingController` subclass. Rows draw their own separators in the theme's colour (live on a theme change).

Notice: keep one `CallRecordingNoticePolicy` (main thread). After `start` returns, call
`beginSending(callSessionId:isOneToOneUser:recorderDidStart:)`; when it is true, send
`CallRecordingNoticePolicy.message(languageCode:)` and later `markDelivered` / `markFailed`. On failure show
`failureMessage(languageCode:)`, stop and delete the recording. `forget` when the call ends.

### macOS adapters

The Mac captures with ScreenCaptureKit (the call window and its audio) and the microphone with SCK on macOS 15+
or `AVCaptureSession` on macOS 14. Its buffers go straight in:

```swift
let center = CallRecordingCenter(
    storage: CallRecordingStorage(directory: recordingsFolder),         // the folder the user picked
    configuration: CallRecordingConfiguration(videoSize: CGSize(width: 1280, height: 720))
)
let session = try center.start(callId: callId, peerName: peerName, onDetach: { stopCapture() })

// SCStreamOutput
func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
    switch type {
    case .audio:
        session.audioTap.appendSampleBuffer(buffer, source: .remote)
    case .microphone:
        session.audioTap.appendSampleBuffer(buffer, source: .microphone)
    case .screen:
        if let frame = CallRecordingVideoFrame(sampleBuffer: buffer) {   // skip idle/blank SCK frames first
            session.appendVideoFrame(frame, side: .remote)
        }
    @unknown default:
        break
    }
}

// AVCaptureAudioDataOutputSampleBufferDelegate (macOS 14)
func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    session.audioTap.appendSampleBuffer(buffer, source: .microphone)
}
```

`appendSampleBuffer` reads Float32, Int16 or Int32 linear PCM (interleaved or not, up to 8 channels, any rate). It
allocates, so call it from the capture queue, never from a real-time audio thread. The remote audio is the
timeline's clock; push it whenever the call plays sound. The Mac keeps its own mute switch and calls
`session.setMuted(_:)`. The whole call window is one picture, so the Mac passes no local side and never needs
`setLayout`.

## Public API

**Core**

- `CallRecordingCenter` (`@MainActor`, `ObservableObject`): `init(storage:configuration:)`,
  `start(callId:peerName:configuration:onDetach:) throws -> CallRecordingSession`, `session(callId:)`, `stop(callId:completion:)`,
  `stop(callId:) async`, `stopAll(timeout:completion:)`, `setLayout(callId:pipCorner:isSwapped:)`,
  `setMuted(callId:isMuted:)`, `isRecording(callId:)`, `state(callId:)`, `stateUpdates(callId:)`,
  `@Published recordingStartDates`.
- `CallRecordingSession`: `callId`, `audioTap`, `appendVideoFrame(_:side:)`, `setMuted(_:)`,
  `setLayout(pipCorner:isSwapped:)`.
- `CallRecordingAudioTap`: `appendPCM(_:frames:channels:sampleRate:isPlayout:)` (real-time safe),
  `appendSampleBuffer(_:source:)`; `CallRecordingAudioSource` (`.microphone`, `.remote`).
- `CallRecordingVideoFrame` (`buffer`: `.pixelBuffer`, `.nv12`, `.i420`; `rotationQuarterTurns`,
  `mirrorHorizontally`, `mirrorVertically`; `init?(sampleBuffer:)`), `CallRecordingVideoSide`,
  `CallRecordingPipCorner`, `CallRecordingVideoLayout`.
- `CallRecordingState`, `CallRecordingError` (`writerFailed`, `nothingRecorded`, `cancelled`, `alreadyRecording`),
  `CallRecordingConfiguration` (`videoSize`, `framesPerSecond` 1...30, `videoBitRate`; `init(quality:)`).
- `CallRecordingStorage`: `init(directory:)`, `.default`, `defaultDirectory`, `fileName(peerName:date:isVideo:)`,
  `list()`, `delete(_:)`, `recoverInterrupted()`; `CallRecording` (`url`, `date`, `duration`, `isVideo`, `size`,
  `peerName`); `CallRecordingName` (`peerName(fromFileName:)`, `initials(of:)`, `colorIndex(of:count:)`).
- `CallRecordingSettings`: keys `novagram_call_recording`, `novagram_call_recording_auto`,
  `novagram_call_recording_warned` in the `pro_messager` suite, an injectable `UserDefaults`, `isEnabled` and
  `isAutoEnabled` (read-write, each is its own key with no second gate), `wasWarned`, `changedNotification`;
  `videoQuality` (key `novagram_call_recording_video_quality`, default battery saver) with `CallRecordingVideoQuality`
  (`.audioOnly` = push no video, `.batterySaver` = 15 fps at half the bit rate, `.high` = 30 fps; `recordsVideo`).
  Start each recording with `configuration: CallRecordingConfiguration(quality: settings.videoQuality)` and push video
  only when `recordsVideo`.
- `CallRecordingSettingsStrings(languageCode:)`: every title and explanation of the "Call recording" settings page
  (en, uz, ru, zh; one text on every platform: no device or platform name, no "tap" / "click"). Both apps draw the same page with their own lists, like the Camera
  page in the system Settings: one row in the app's settings (`title`, `on` / `off`) opens it; RECORDING with the
  switch and `recordFooter`; the auto switch and `autoFooter` while recording is on; VIDEO QUALITY (`qualityHeader`,
  the three `qualityTitle(_:)` choices with a checkmark, `qualityFooter`) while recording is on; RECORDINGS with the list row and
  `recordingsFooter` (always shown); PRIVACY with `privacyText`, which quotes the chat notice word for word.
- `CallRecordingNoticePolicy`: `beginSending(callSessionId:isOneToOneUser:recorderDidStart:)`, `markDelivered`,
  `markFailed`, `forget`, `status`, `message(languageCode:)`, `failureMessage(languageCode:)`;
  `CallRecordingLanguage` (en, uz, ru, zh).

**UI**

- `CallRecordingsListView(storage:environment:)`, `CallRecordingsListView(model:environment:)`.
- `CallRecordingUIEnvironment`: `theme`, `strings`, `isRecordingEnabled`, `dayHeader`, `sizeString`, `timeString`,
  `durationString`, `spokenDuration`, `onPlay`, `onShare`, `showsToolbar`, `showsSelectionBar`, `confirmDeletion`.
- `CallRecordingTheme` (colours, avatar gradients, font sizes, `followsDynamicType`, `listSideInset`), `CallRecordingStrings`
  (en/uz/ru/zh built in, every value overridable), `CallRecordingFormatters`.
- `CallRecordingsListViewModel` (`reload()`, `delete(_:)`, `filter`, `isSelecting`, `selection`, `setSelecting(_:)`,
  `selectedURLs`, `allVisibleSelected`, `toggleSelectAll()`, `requestClearAll()`, `requestDeleteSelected()`),
  `CallRecordingsListModel` (`sections`,
  `summary`, `subtitle`, `clearConfirmation`), `CallRecordingFilter`, `CallRecordingDaySection`.

## Threading

- `CallRecordingCenter` is main-actor only. `stop` completions run on the main actor; `stopAll`'s completion runs on
  a background queue, so `applicationWillTerminate` may wait for it.
- `CallRecordingSession` and `CallRecordingAudioTap` may be used from any thread. Push each audio source from one
  thread at a time.
- Each recorder owns a serial queue; nothing in the SDK blocks the main thread.

## Files

A recording is written to `<folder>/.partial/<uuid>/<peer> yyyy-MM-dd HH.mm.mp4` and moved into the folder when it
is finished (`.m4a` if no video ever came). Movie fragments every 2 seconds keep a file playable if the app is
killed; the next `CallRecordingCenter` or `list()` in a new process moves it in. The duration is stored in the
extended attribute `uz.novagram.callrecording.duration`.

## Tests

```sh
swift test
xcodebuild -scheme NovagramCallRecordingKit-Package -destination 'generic/platform=iOS Simulator' build
```

`NovagramCallRecordingCoreTests` covers the ring, the mixer, the sample buffer conversion, orientation, the
compositor's corners and swap, file naming, recovery, the notice policy, the settings keys and real end-to-end
writer runs (voice to `.m4a`, video to `.mp4`, video turned on halfway, nothing recorded, stop-all).
`NovagramCallRecordingUITests` covers the day sections, the filters, the plurals, the formatters and the view
model. The composed-picture pixel checks need Metal and return early without it.
