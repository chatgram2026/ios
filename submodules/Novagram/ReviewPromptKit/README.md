# NovagramReviewPromptKit

The App Store rating prompt rules shared by the Novagram iOS app (Bazel) and the Novagram macOS app (SwiftPM). Both
apps have the bundle id `uz.fenixuz.app`, so they share one App Store record (id `6768202244`) and one set of rules.

The SDK counts successful uses of Novagram features. Once the user has used one feature successfully 5 times, it may
ask Apple's system prompt at a natural break, such as returning to the chat list. Each app keeps its own hook points:
it calls `recordSuccess(_:)` where a feature succeeds and `requestReviewIfAppropriate` at its natural break.

Foundation, StoreKit and UIKit/AppKit only. No Telegram module and no third-party dependency.

## License

GPL-2.0-or-later. `LICENSE` holds the GPL version 2 text; every source file starts with
`// SPDX-License-Identifier: GPL-2.0-or-later`. The SDK ships as source, never as a binary.

## Apple's rules, built in

The SDK only calls Apple's system prompt (App Review Guideline 5.6.1):

- iOS 16+: `AppStore.requestReview(in: UIWindowScene)`; iOS 15: `SKStoreReviewController.requestReview(in:)`.
- macOS 13+: `AppStore.requestReview(in: NSViewController)`; macOS 10.14-12: `SKStoreReviewController.requestReview()`.

What the SDK never does:

- No rating UI of its own: no alert, no "Enjoying the app? Yes/No" question, no custom stars, no automatic opening of
  the App Store review page.
- No filtering or targeting by age, birthday, mood or sentiment, and no reward of any kind.
- No prompt from a button. A Settings "Rate Novagram" row opens the write-review page
  (`ReviewPromptLinks.writeReviewURL()`) instead: `https://apps.apple.com/app/id6768202244?action=write-review` on
  iOS, `macappstore://apps.apple.com/app/id6768202244?action=write-review` on macOS (the App Store app, not the
  browser).
- No "shown" flag. The system shows its prompt at most 3 times in 365 days and may show nothing; the app cannot know.
  The SDK stores that it _requested_, never that anything was shown.

Hosts must not gate the prompt for chosen user groups either (by account, country, age, purchase or feedback). Every
user who uses the app gets the same rules.

## Rules (`ReviewPromptPolicy`)

| Rule                         | Default     | Meaning                                                                                                                   |
| ---------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------- |
| `requiredSuccesses`          | 5           | New successes of one feature since the last request (or ever, before the first). 3 + 2 of two features is not enough. |
| `countedFeatures`            | 11 features | `defaultCountedFeatures`: every feature except `autoTranslate` and `callRecordingSaved` (see below). Others are stored but ignored. |
| `minimumDaysAfterStart`      | 3           | The start is the first time the SDK sees the device, or the last `noteFreshStart()`.                                     |
| `minimumDaysBetweenRequests` | 14          | Days after the previous request.                                                                                          |
| `oneRequestPerAppVersion`    | true        | At most one request per app version.                                                                                      |
| `delayBeforeRequest`         | 2 s         | Wait at the natural break, then check the rules and `isBusy` again before asking.                                        |

**Counted features.** Both apps count the same 11 features, decided once, so the set is the SDK default
(`ReviewPromptPolicy.defaultCountedFeatures`). Two features are left out:

- `autoTranslate` runs by itself on every sent message, so 5 counts pile up in minutes and show no engagement.
- `callRecordingSaved` is an unapproved feature that only shows in a hidden Developer section.

Each app still reports every feature it has, and a host may pass its own set.

**Asking again (rule C).** There is at most one request per app version, and after every request the user needs
`requiredSuccesses` (5) **new** successes of one counted feature before the next one. When a request is stored, the
SDK stores the counts at that moment as a baseline (`successCountsAtLastRequest`), and use is measured from it
(`newSuccessCount(for:)`). So a new version alone, or 14 days alone, never brings the prompt back. The user needs 5
new uses of one feature, 14 days since the last request, and a new version.

The decision checks, in this order, and the first one that fails is the reason (the tests pin this order):

1. an app version that is not empty (`invalidAppVersion`);
2. use (`notEnoughUse`);
3. time since the start (`tooSoonAfterStart`);
4. this version (`alreadyRequestedThisVersion`);
5. time since the last request (`cooldown`).

A stored date after now means the clock was set back. It counts as the moment the center noticed it, so it delays a
request by at most the normal 3 or 14 days instead of months.

## Public API

```swift
public enum ReviewPromptFeature: String, CaseIterable, Codable, Sendable
// editedHistory, translateMessage, autoTranslate, speechToText, voiceTranslate, storySave, roundVideoFromGallery,
// forwardWithoutNames, ghostMode, chatLockUnlock, secretVaultUnlock, callRecordingSaved, viewFirstMessage

public struct ReviewPromptPolicy: Equatable, Sendable {
    static let defaultCountedFeatures: Set<ReviewPromptFeature>   // all but autoTranslate and callRecordingSaved
    init(requiredSuccesses: Int = 5, countedFeatures: Set<ReviewPromptFeature> = defaultCountedFeatures,
         minimumDaysAfterStart: Int = 3,
         minimumDaysBetweenRequests: Int = 14, oneRequestPerAppVersion: Bool = true, delayBeforeRequest: TimeInterval = 2)
    func decision(for state: ReviewPromptState, appVersion: String, now: Date) -> ReviewPromptDecision
}

public enum ReviewPromptDecision: Equatable, Sendable, CustomStringConvertible {
    case eligible, invalidAppVersion, notEnoughUse, tooSoonAfterStart(until: Date), alreadyRequestedThisVersion,
         cooldown(until: Date)
    var isEligible: Bool
}

public enum ReviewPromptRequestResult: Equatable, Sendable, CustomStringConvertible {
    case requested, skipped(ReviewPromptDecision), busy, alreadyPending, unavailable
}

public final class ReviewPromptCenter: @unchecked Sendable {
    static let suiteName = "pro_messager"
    static let stateKey = "novagram_review_prompt_state"
    static func novagramDefaults() -> UserDefaults
    init(policy: ReviewPromptPolicy = .init(), defaults: UserDefaults = novagramDefaults(),
         now: @escaping @Sendable () -> Date = { Date() },
         scheduler: any ReviewPromptScheduling = ReviewPromptMainQueueScheduler(),
         presenter: any ReviewPromptPresenting = ReviewPromptSystemPresenter())
    let policy: ReviewPromptPolicy
    let defaults: UserDefaults
    var state: ReviewPromptState { get }                      // any thread, never writes
    func recordSuccess(_ feature: ReviewPromptFeature)        // any thread
    func noteFreshStart()                                     // any thread
    func decision(appVersion: String, now: Date? = nil) -> ReviewPromptDecision   // any thread, never writes
    // iOS
    @MainActor func requestReviewIfAppropriate(appVersion: String, in scene: UIWindowScene,
        isBusy: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor (ReviewPromptRequestResult) -> Void = { _ in })
    // macOS
    @MainActor func requestReviewIfAppropriate(appVersion: String, in window: NSWindow? = nil,
        isBusy: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor (ReviewPromptRequestResult) -> Void = { _ in })
}

public struct ReviewPromptState: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1
    var startDate: Date? { get }
    var successCounts: [String: Int] { get }
    var lastRequestDate: Date? { get }
    var lastRequestedAppVersion: String? { get }
    var successCountsAtLastRequest: [String: Int] { get }   // the baseline; empty before the first request
    func successCount(for feature: ReviewPromptFeature) -> Int
    func newSuccessCount(for feature: ReviewPromptFeature) -> Int   // since the last request
}

@MainActor public protocol ReviewPromptPresenting {
    func requestReview(in target: ReviewPromptTarget?) -> Bool
}
public struct ReviewPromptSystemPresenter: ReviewPromptPresenting   // nonisolated init()
public typealias ReviewPromptTarget = UIWindowScene                 // NSWindow on macOS

@MainActor public protocol ReviewPromptScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void)
}
public struct ReviewPromptMainQueueScheduler: ReviewPromptScheduling   // nonisolated init()

public enum ReviewPromptLinks {
    static let novagramAppStoreId = 6768202244
    static func writeReviewURL(appStoreId: Int = novagramAppStoreId) -> URL?   // https on iOS, macappstore on macOS
}

public struct ReviewPromptStrings: Equatable, Sendable {
    init(languageCode: String)
    var rateTitle: String       // "Rate Novagram"
    var feedbackTitle: String   // "Send feedback"
    var footer: String          // "Your rating helps other people find Novagram."
}
public enum ReviewPromptLanguage: String, Sendable, CaseIterable
// en, uz, ru, zh (Simplified), zh-hant (Traditional: a Hant script, or TW/HK/MO without Hans); anything else is English
```

## Threading

Read this before adding a hook.

- `recordSuccess`, `noteFreshStart`, `state` and `decision` may be called from any thread. They take a short lock that
  guards only the center's in-memory copy, and they never call out while holding it.
- The `UserDefaults` write runs later, in order, on the SDK's private serial queue. `UserDefaults.set` posts
  `UserDefaults.didChangeNotification` synchronously, so **host observers of that notification run on that private
  queue**, not on the thread that called `recordSuccess`. An observer registered with `queue: .main` makes that queue
  wait for the main thread. This is safe, because the SDK never makes the main thread wait for the queue.
- Do not call into the SDK synchronously from such an observer and then wait for the main thread. Never block the main
  thread on work that itself calls `recordSuccess`.
- `requestReviewIfAppropriate` is main-actor only. Its `isBusy` and `completion` run on the main actor.
- Keep **one center per app**. Each center works on its own in-memory copy, so two centers on one suite in one process
  would overwrite each other's counts. A new center reads what earlier writes stored. A write that is still queued
  lands a moment later.

## The request

`requestReviewIfAppropriate` runs on the main actor:

1. If another request is waiting for its delay: `.alreadyPending`.
2. If the rules say no: `.skipped(decision)`. If the stored state comes from a newer SDK: `.unavailable`. If `isBusy()`:
   `.busy`. Nothing is scheduled.
3. Otherwise it waits `delayBeforeRequest`, then checks the rules and `isBusy()` again (a login, a call or another
   request may have happened during the delay).
4. It calls the presenter. If the presenter could not ask, the result is `.unavailable`. That happens when:
   - the app is not active;
   - on iOS, the scene is not in the foreground;
   - on macOS, the window is gone, hidden or minimised;
   - the system is macOS 10.13.

   Otherwise it stores the request (date, app version) and reports `.requested`.

Nothing is stored for `.busy` or `.unavailable`, so the next natural break may try again. If the center is released
during the delay, nothing is asked and the completion is not called.

On macOS the presenter uses the window's `contentViewController`. A window without one, such as the Mac app's TGUIKit
windows, gets a zero-size anchor view controller added to its content view. The last anchor stays until the next
request replaces it.

`isBusy` is the host's "the user is in the middle of something": a call, a recording, typing, an unlock, a payment,
an open sheet.

## Storage

One JSON value under the key `novagram_review_prompt_state` in the `UserDefaults` suite `pro_messager`, which both
apps already use (the standard defaults if the suite cannot be opened). Dates are seconds since 1970:

```json
{
  "formatVersion": 1,
  "lastRequestDate": 1800259200,
  "lastRequestedAppVersion": "2.0.15",
  "startDate": 1800000000,
  "successCounts": { "ghostMode": 2, "translateMessage": 5 },
  "successCountsAtLastRequest": { "translateMessage": 5 }
}
```

- Reading never writes: `state`, `decision` and a new center leave the stored bytes alone. The one exception is a new
  center that finds nothing usable stored. It stores the start (the first time the SDK sees the device).
- Every field decodes on its own. A bad or missing field reads as empty and never erases the others. Data that is not a
  JSON object reads as a fresh state that starts now.
- Data with a `formatVersion` above the SDK's (written by a newer build, then the user went back to an older one) is
  read but never overwritten. Such a center never asks.
- `successCounts` is keyed by the feature's raw value. The raw values are stored on users' devices: never rename one.
  A key this build does not know (a newer version's feature) is kept.
- `successCountsAtLastRequest` is written only once a request was made. Data without it, including everything the
  first SDK version (f070eec) wrote, reads as a zero baseline, and `formatVersion` stays 1. An older build that rewrites
  the state drops the field. After going back to a newer build, the counts so far then count as new, and the version
  and 14-day rules still apply.
- New successes since the last request stop at 1000. A success past that is not written at all.
- `noteFreshStart()` restarts the 3-day start delay from now. Call it after a login; a fresh install starts on its own.
  Counts and the last request are kept, so a new login never allows an extra request.

To test the flow again on a development device (a Developer section row, never a user-visible one), remove the key
with `ReviewPromptCenter.novagramDefaults().removeObject(forKey: ReviewPromptCenter.stateKey)` and relaunch.

## Integration

Both apps add this repository as a git submodule pinned by commit (no tags) and update it by moving the pin.

**iOS (Bazel).** Add the submodule at `submodules/Novagram/ReviewPromptKit`; its root `BUILD` exposes
`//submodules/Novagram/ReviewPromptKit:NovagramReviewPromptCore` (built with `-warnings-as-errors`).

**macOS (SwiftPM).** Add the submodule and reference it as a local package
(`.package(path: "../novagram-review-prompt-kit-sdk")`), then depend on the `NovagramReviewPromptCore` product.

Both examples below compile as written against the SDK (checked with `swiftc -typecheck`). The host supplies the
`isBusy` closure and its own logger.

### iOS

```swift
import UIKit
import NovagramReviewPromptCore

// One per app.
let reviewPrompt = ReviewPromptCenter()

// After a login; a fresh install starts on its own.
func didLogIn() {
    reviewPrompt.noteFreshStart()
}

// Where a feature succeeds; any thread.
func didTranslateMessage() {
    reviewPrompt.recordSuccess(.translateMessage)
}

// At a natural break, e.g. the chat list appeared again.
@MainActor
func chatListDidAppear(in scene: UIWindowScene, isBusy: @escaping @MainActor () -> Bool, log: @escaping @MainActor (String) -> Void) {
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    reviewPrompt.requestReviewIfAppropriate(appVersion: appVersion, in: scene, isBusy: isBusy, completion: { result in
        log("ReviewPrompt: \(result)")
    })
}

// The Settings "Rate Novagram" row opens the write-review page, never the system prompt.
@MainActor
func rateRowSelected() {
    if let url = ReviewPromptLinks.writeReviewURL() {
        UIApplication.shared.open(url)
    }
}
```

The Settings rows take their texts from `ReviewPromptStrings(languageCode: presentationData.strings.baseLanguageCode)`.

### macOS

The Mac app deploys to macOS 14, so it always gets `AppStore.requestReview(in: NSViewController)`. The
`SKStoreReviewController` path exists only for the package minimum (macOS 10.14-12); on macOS 10.13 the request reports
`.unavailable`. The Mac app already has the App Store id `6768202244` in `AppConstants.swift` (`itunesAppLink`, a
string); it equals `ReviewPromptLinks.novagramAppStoreId`, which `writeReviewURL()` uses by default.

```swift
import AppKit
import NovagramReviewPromptCore

let reviewPrompt = ReviewPromptCenter()

// Where a feature succeeds; any thread.
func didViewFirstMessage() {
    reviewPrompt.recordSuccess(.viewFirstMessage)
}

// At a natural break. A nil window means the key window; a window without a contentViewController works.
@MainActor
func chatListDidAppear(in window: NSWindow?, isBusy: @escaping @MainActor () -> Bool, log: @escaping @MainActor (String) -> Void) {
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    reviewPrompt.requestReviewIfAppropriate(appVersion: appVersion, in: window, isBusy: isBusy, completion: { result in
        log("ReviewPrompt: \(result)")
    })
}

// The Settings "Rate Novagram" row opens the App Store app (macappstore://), never the system prompt.
@MainActor
func rateRowSelected() {
    if let url = ReviewPromptLinks.writeReviewURL() {
        NSWorkspace.shared.open(url)
    }
}
```

### Verifying in a host

- Development builds (run from Xcode or `run.sh`) show the system sheet on every request, so they only prove the call
  is reached.
- TestFlight builds never show it.
- The App Store build shows it at the system's discretion.

So hosts verify the logic through `decision(appVersion:)` and the logged `ReviewPromptRequestResult`, not by looking
for the sheet.

## Platforms and language modes

iOS 15 and macOS 10.13 (the package minimum, so a host that deploys low can depend on it). Only the system calls are
gated, inside `ReviewPromptSystemPresenter`. Swift 6 language mode in SwiftPM. The sources also build in Swift 5 mode
with `-warnings-as-errors` (checked as below), so the Bazel target works in either language mode. They stay
warning-free with deployment targets up to iOS 26 and macOS 26, where the old StoreKit calls are deprecated.

## Tests

```sh
swift build
swift test
xcodebuild -scheme NovagramReviewPromptKit -destination 'generic/platform=iOS Simulator' build

# Swift 5 and 6 modes with warnings as errors, at low and high deployment targets.
for t in x86_64-apple-macos10.13:macosx arm64-apple-macos26.0:macosx \
         arm64-apple-ios15.0-simulator:iphonesimulator arm64-apple-ios26.0-simulator:iphonesimulator; do
  for v in 5 6; do
    swiftc -typecheck -module-name NovagramReviewPromptCore -sdk "$(xcrun --show-sdk-path --sdk ${t#*:})" \
      -target ${t%%:*} -swift-version $v -warnings-as-errors Sources/NovagramReviewPromptCore/*.swift \
      && echo "ok $t swift $v" || echo "FAILED $t swift $v"
  done
done
```

`NovagramReviewPromptCoreTests` (XCTest) covers:

- the per-feature threshold, the 11 default counted features, the counted-features filter, an empty app version and
  the order of the checks;
- asking again (rule C): a new version alone is not enough, 4 new successes are not enough, 5 new successes plus 14
  days plus a new version are, only counted features count as new, the baseline moves with each request, and the cap
  counts new successes;
- the start delay, `noteFreshStart` (it restarts the delay and keeps the request history), the 14-day cooldown, one
  request per version and a clock set back;
- `isBusy` blocking before and after the delay, the rules being checked again after it, one pending request at a time,
  a presenter that cannot ask, a released center and the main-queue scheduler;
- the JSON under one key, the round trip, JSON without the baseline (as the first SDK version wrote it), reads that
  never write, a newer format left untouched, one bad field, corrupt,
  missing and wrong-type data, unknown features, the count cap, `recordSuccess` from many threads, and a regression
  test for the deadlock with a host's `UserDefaults.didChangeNotification` observer (it fails with a timeout instead of
  hanging);
- the write-review URL (`macappstore://` on macOS);
- the texts. All 15 user-visible strings (3 rows in en, uz, ru, zh, zh-Hant) are pinned to exact values, so any change
  to any language fails. On top of that, every text is checked against
  `\b(iPhone|iPad|iPod|Mac|macOS|iOS|iPadOS|Apple|Android|tap|click)\b` (case-insensitive), which only catches English
  words. The English texts are also checked against reward words (`free`, `reward`, `gift`, `bonus`, `prize`,
  `premium`). Nothing checks the meaning of the other languages: the pinned values were reviewed by hand.

Tests use one fixed defaults suite, `NovagramReviewPromptTests`, emptied before and after each test.

The system prompt itself cannot be unit-tested. It sits behind `ReviewPromptPresenting`, and the tests inject a spy.
