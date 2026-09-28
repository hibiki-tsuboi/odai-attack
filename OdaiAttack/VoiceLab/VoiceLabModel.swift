//
//  VoiceLabModel.swift
//  OdaiAttack
//

import Foundation
import Observation

/// 音声判定画面（フェーズ2）の状態と操作。
@Observable
final class VoiceLabModel {
    enum State: Equatable {
        case idle
        case preparing(String)
        case listening
        case stopping
    }

    var topic = "赤いもの"
    private(set) var state = State.idle
    /// 認識中でまだ確定していない文字列。
    private(set) var partialText = ""
    private(set) var level: Float = -160
    private(set) var threshold: Float = SpeechTuning.minimumSpeechDB
    private(set) var isSpeaking = false
    private(set) var errorMessage: String?

    /// Jev への接続先が設定されていないと nil。
    private let wordList: SpokenWordList?
    private let audio = AudioIO()
    private var recognizer: SpeechWordRecognizer?
    private var eventsTask: Task<Void, Never>?

    init(client: (any JevClient)? = makeConfiguredJevClient()) {
        wordList = client.map { SpokenWordList(judge: WordJudge(client: $0)) }
    }

    var isConnectionMissing: Bool { wordList == nil }

    /// 確定した言葉（言った順）。
    var entries: [SpokenEntry] { wordList?.entries ?? [] }

    var canToggleListening: Bool {
        switch state {
        case .idle: wordList != nil && !trimmedTopic.isEmpty
        case .listening: true
        case .preparing, .stopping: false
        }
    }

    var statusText: String {
        switch state {
        case .idle: "ボタンを押して、お題に合う言葉を声で言ってください"
        case .preparing(let message): message
        case .listening: "聞いています。もう一度押すと止まります"
        case .stopping: "最後の言葉を確定しています…"
        }
    }

    func toggleListening() async {
        switch state {
        case .idle: await startListening()
        case .listening: await stopListening()
        case .preparing, .stopping: break
        }
    }

    func stopListening() async {
        guard state == .listening, let recognizer else { return }
        state = .stopping
        audio.stop()
        // 止める直前に言った言葉も確定させて判定する
        await recognizer.finish()
        await eventsTask?.value
        eventsTask = nil
        self.recognizer = nil
        partialText = ""
        level = -160
        isSpeaking = false
        state = .idle
    }

    func clear() {
        wordList?.clear()
    }

    private func startListening() async {
        guard canToggleListening, state == .idle, let wordList else { return }
        errorMessage = nil
        state = .preparing("マイクと音声認識の許可を確認しています…")
        do {
            try await AudioIO.requestPermissions()
            state = .preparing("音声認識を準備しています…")
            let recognizer = try await SpeechWordRecognizer.make { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, case .preparing = self.state else { return }
                    self.state = .preparing("音声モデルをダウンロードしています（\(Int(progress * 100))%）")
                }
            }
            do {
                try audio.start()
                try audio.startCapture(feeding: recognizer)
            } catch {
                audio.stop()
                await recognizer.finish()
                throw error
            }
            self.recognizer = recognizer
            wordList.topic = trimmedTopic
            state = .listening
            eventsTask = Task { [weak self] in
                for await event in recognizer.events {
                    self?.handle(event)
                }
            }
        } catch {
            state = .idle
            errorMessage = SpeechRecognitionError.describe(error)
        }
    }

    private func handle(_ event: SpeechWordRecognizer.Event) {
        switch event {
        case .partial(let text):
            partialText = text
        case .words(let words, let speechEndedAt):
            for word in words {
                wordList?.add(word, speechEndedAt: speechEndedAt)
            }
        case .level(let level, let threshold, let isSpeaking):
            self.level = level
            self.threshold = threshold
            self.isSpeaking = isSpeaking
        case .failed(let message):
            errorMessage = message
        }
    }

    private var trimmedTopic: String { topic.trimmingCharacters(in: .whitespacesAndNewlines) }
}
