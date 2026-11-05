import Foundation
import UIKit
import AVFoundation
import Speech
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ChitgramCore

/// Live dictation with the system speech recogniser (Android `VoiceDictation`): it keeps listening across pauses
/// until the user stops it, as on Android, and reports the whole text so far after every phrase.
private final class ChitgramDictation {
    private let locale: Locale?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    /// Phrases the recogniser has finished; a new recognition task starts after each one.
    private var committed = ""
    /// Recognition tasks in a row that heard nothing; a recogniser that keeps failing is not restarted forever.
    private var emptyRuns = 0
    /// Whether the current recognition task has heard anything yet.
    private var heardSomething = false
    private(set) var text = ""

    var updated: ((String) -> Void)?
    var failed: (() -> Void)?

    init(locale: Locale?) {
        self.locale = locale
    }

    deinit {
        self.task?.cancel()
        self.stopAudio()
    }

    func start() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                if status == .authorized {
                    self.begin()
                } else {
                    self.failed?()
                }
            }
        }
    }

    private func makeRecognizer() -> SFSpeechRecognizer? {
        if let locale = self.locale {
            return SFSpeechRecognizer(locale: locale)
        }
        return SFSpeechRecognizer()
    }

    private func begin() {
        guard let recognizer = self.makeRecognizer(), recognizer.isAvailable else {
            self.failed?()
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            self.failed?()
            return
        }
        let input = self.audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: { [weak self] buffer, _ in
            self?.request?.append(buffer)
        })
        self.audioEngine.prepare()
        do {
            try self.audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.failed?()
            return
        }
        self.running = true
        self.listen(recognizer: recognizer)
    }

    /// One recognition task; when it ends on a pause while the user is still dictating, the next one starts.
    private func listen(recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        self.heardSomething = false
        self.task = recognizer.recognitionTask(with: request, resultHandler: { [weak self] result, error in
            let partial = result?.bestTranscription.formattedString
            let finished = error != nil || (result?.isFinal ?? false)
            DispatchQueue.main.async {
                guard let self, self.request === request else {
                    return
                }
                if let partial, !partial.isEmpty {
                    self.heardSomething = true
                    self.text = self.committed.isEmpty ? partial : self.committed + " " + partial
                    self.updated?(self.text)
                }
                if finished {
                    self.committed = self.text
                    self.emptyRuns = self.heardSomething ? 0 : self.emptyRuns + 1
                    if self.emptyRuns >= 5 {
                        self.stopAudio()
                        if self.text.isEmpty {
                            self.failed?()
                        }
                    } else if self.running {
                        // A moment for the recogniser to settle (Android: 120 ms).
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: {
                            guard self.running, self.request === request else {
                                return
                            }
                            self.listen(recognizer: recognizer)
                        })
                    }
                }
            }
        })
    }

    func stop() {
        self.request?.endAudio()
        self.request = nil
        self.stopAudio()
    }

    func cancel() {
        self.task?.cancel()
        self.request = nil
        self.stopAudio()
    }

    private func stopAudio() {
        if self.running {
            self.running = false
            self.audioEngine.stop()
            self.audioEngine.inputNode.removeTap(onBus: 0)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

private var chitgramHasRecognizerCache: Bool?

/// Whether the device has a speech recogniser at all (Android `hasRecognizer`): without one the mic would be a dead
/// button, so it is hidden, and so is its switch.
public func chitgramHasSpeechRecognizer() -> Bool {
    if let value = chitgramHasRecognizerCache {
        return value
    }
    let value = SFSpeechRecognizer.authorizationStatus() != .restricted && SFSpeechRecognizer() != nil
    chitgramHasRecognizerCache = value
    return value
}

/// The one gate every voice-input entry asks (Android `isMicVisible`): the composer mic and the chat menu's item.
public func chitgramVoiceInputIsAvailable() -> Bool {
    return ChitgramPreferences.shared.bool(.dictationMicEnabled) && chitgramHasSpeechRecognizer()
}

/// The languages offered for speaking: Telegram's translation languages the recogniser knows.
private func chitgramSpeakLanguages() -> [String] {
    let supported = Set(SFSpeechRecognizer.supportedLocales().map { locale in
        return String(locale.identifier.prefix(while: { $0 != "-" && $0 != "_" }))
    })
    return ChitgramAutoTranslate.languages.filter { supported.contains($0) }
}

/// Picks a language: the first row is "device default" or "off" (empty code), the rest are the languages. `done`
/// runs after a pick or a cancel.
private func chitgramPickLanguage(context: AccountContext, title: String, firstTitle: String, languages: [String], current: String, present: @escaping (ViewController) -> Void, picked: @escaping (String) -> Void, done: @escaping () -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let actionSheet = ActionSheetController(presentationData: presentationData)
    var items: [ActionSheetItem] = [ActionSheetTextItem(title: title, parseMarkdown: false)]
    for code in [""] + languages {
        let name = code.isEmpty ? firstTitle : ChitgramAutoTranslate.displayName(code)
        items.append(ActionSheetButtonItem(title: (code == current ? "\u{2713} " : "") + name, color: .accent, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            picked(code)
            done()
        }))
    }
    actionSheet.setItemGroups([
        ActionSheetItemGroup(items: items),
        ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: ChitgramStrings.get(80), color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                done()
            })
        ])
    ])
    present(actionSheet)
}

/// The chat menu's "Voice to text" (Android `VoiceTranslateSheet`): the language spoken and the one to translate to
/// ("Off" means dictation only), both kept on this device, then Start begins dictating.
public func chitgramPresentVoiceToText(context: AccountContext, present: @escaping (ViewController) -> Void, completion: @escaping (String) -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let preferences = ChitgramPreferences.shared
    let actionSheet = ActionSheetController(presentationData: presentationData)

    let speakTitle: () -> String = {
        let code = preferences.string(.dictationFrom)
        return "\(ChitgramStrings.get(313)): \(code.isEmpty ? ChitgramStrings.get(312) : ChitgramAutoTranslate.displayName(code))"
    }
    let translateTitle: () -> String = {
        let code = preferences.string(.dictationTo)
        return "\(ChitgramStrings.get(314)): \(code.isEmpty ? ChitgramStrings.get(315) : ChitgramAutoTranslate.displayName(code))"
    }

    actionSheet.setItemGroups([
        ActionSheetItemGroup(items: [
            ActionSheetTextItem(title: ChitgramStrings.get(308), font: .large, parseMarkdown: false),
            // A language is picked in a list of its own; this sheet comes back after it with the new choice.
            ActionSheetButtonItem(title: speakTitle(), color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                chitgramPickLanguage(context: context, title: ChitgramStrings.get(313), firstTitle: ChitgramStrings.get(312), languages: chitgramSpeakLanguages(), current: preferences.string(.dictationFrom), present: present, picked: { code in
                    preferences.set(code, for: .dictationFrom)
                }, done: {
                    chitgramPresentVoiceToText(context: context, present: present, completion: completion)
                })
            }),
            ActionSheetButtonItem(title: translateTitle(), color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                chitgramPickLanguage(context: context, title: ChitgramStrings.get(314), firstTitle: ChitgramStrings.get(315), languages: ChitgramAutoTranslate.languages, current: preferences.string(.dictationTo), present: present, picked: { code in
                    preferences.set(code, for: .dictationTo)
                }, done: {
                    chitgramPresentVoiceToText(context: context, present: present, completion: completion)
                })
            }),
            ActionSheetButtonItem(title: ChitgramStrings.get(316), color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                chitgramStartDictation(context: context, present: present, completion: completion)
            })
        ]),
        ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])
    ])
    present(actionSheet)
}

/// Dictation with the saved languages (the composer mic, and Start above): the text shows as it is recognised, and
/// Done translates it when a language to translate to is set (Android: translated once, at the end).
public func chitgramStartDictation(context: AccountContext, present: (ViewController) -> Void, completion: @escaping (String) -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let preferences = ChitgramPreferences.shared
    let speak = preferences.string(.dictationFrom)
    let dictation = ChitgramDictation(locale: speak.isEmpty ? nil : Locale(identifier: speak))
    let actionSheet = ActionSheetController(presentationData: presentationData)

    let finish: (String) -> Void = { text in
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return
        }
        let language = preferences.string(.dictationTo)
        if language.isEmpty {
            completion(text)
            return
        }
        let _ = (context.engine.messages.translate(text: text, toLang: language)
        |> deliverOnMainQueue).startStandalone(next: { result in
            completion(result?.0 ?? text)
        }, error: { _ in
            // Android: "Translation failed", and the dictated text stays.
            completion(text)
        })
    }

    actionSheet.setItemGroups([
        ActionSheetItemGroup(items: [
            ActionSheetTextItem(title: ChitgramStrings.get(308), font: .large, parseMarkdown: false),
            ActionSheetTextItem(title: ChitgramStrings.get(309), parseMarkdown: false),
            ActionSheetButtonItem(title: presentationData.strings.Common_Done, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                dictation.stop()
                finish(dictation.text)
            })
        ]),
        ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                dictation.cancel()
            })
        ])
    ])
    dictation.updated = { [weak actionSheet] text in
        actionSheet?.updateItem(groupIndex: 0, itemIndex: 1, { _ in
            return ActionSheetTextItem(title: text, font: .large, parseMarkdown: false)
        })
    }
    dictation.failed = { [weak actionSheet] in
        actionSheet?.updateItem(groupIndex: 0, itemIndex: 1, { _ in
            return ActionSheetTextItem(title: ChitgramStrings.get(310), parseMarkdown: false)
        })
    }
    present(actionSheet)
    dictation.start()
}
