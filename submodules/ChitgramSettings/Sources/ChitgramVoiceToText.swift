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

/// Live dictation with the system speech recogniser (Android `VoiceDictation`).
private final class ChitgramDictation {
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    private(set) var text = ""

    var updated: ((String) -> Void)?
    var failed: (() -> Void)?

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

    private func begin() {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
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
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let input = self.audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: { buffer, _ in
            request.append(buffer)
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
        self.request = request
        self.task = recognizer.recognitionTask(with: request, resultHandler: { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let finished = error != nil || (result?.isFinal ?? false)
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                if let text {
                    self.text = text
                    self.updated?(text)
                }
                if finished {
                    self.stopAudio()
                }
            }
        })
    }

    func stop() {
        self.request?.endAudio()
        self.stopAudio()
    }

    func cancel() {
        self.task?.cancel()
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

/// The chat menu's "Voice to text" (Android `VoiceTranslateSheet`): dictate, then the text goes into the chat's input
/// box, translated first when the chat has an auto-translate language.
public func chitgramPresentVoiceToText(context: AccountContext, chat: Int64, present: (ViewController) -> Void, completion: @escaping (String) -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let dictation = ChitgramDictation()
    let actionSheet = ActionSheetController(presentationData: presentationData)

    let finish: (String) -> Void = { text in
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return
        }
        guard let language = ChitgramAutoTranslate.language(chat) else {
            completion(text)
            return
        }
        let _ = (context.engine.messages.translate(text: text, toLang: language)
        |> deliverOnMainQueue).startStandalone(next: { result in
            completion(result?.0 ?? text)
        }, error: { _ in
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
