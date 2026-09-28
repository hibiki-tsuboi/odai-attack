//
//  SpeechWordRecognizer.swift
//  OdaiAttack
//

import AVFoundation
import Accelerate
import CoreMedia
import Foundation
import Speech
import Synchronization
import os

/// 日本語の声を文字起こしし、話の切れ目ごとに言葉を確定させる。
///
/// 使っている API は SpeechAnalyzer + DictationTranscriber（iOS 26 からの音声認識）と、音声を認識用の形式に変える
/// AnalyzerInputConverter（iOS 27）。同じく SpeechAnalyzer で使える SpeechTranscriber より、DictationTranscriber のほうが
/// 認識途中の結果が届く間隔が短い（Mac での計測で、SpeechTranscriber は約1秒ごと、DictationTranscriber は0.1〜0.3秒ごと）。
///
/// 区切り方: 音量で話し終わり（無音）を検出したら `finalize(through:)` で認識を確定させ、確定した文字列を言葉として届ける。
/// 無音を検出できないとき（騒がしいときなど）は、認識中の文字列がしばらく変わらなければ確定する。
/// パラメータは `SpeechTuning` にまとめている。
///
/// 音声は `append(_:)` で渡す。マイク以外の音声でも試せるように、マイクの扱いは `MicrophoneCapture` に分けている。
nonisolated final class SpeechWordRecognizer: Sendable {
    enum Event: Sendable {
        /// 認識中でまだ確定していない文字列。確定すると空になる。
        case partial(String)
        /// 確定した言葉（言った順）。無音で区切ったときは、話し終わったおおよその時刻も付く。
        case words([String], speechEndedAt: ContinuousClock.Instant?)
        /// 入力の音量と、声とみなすしきい値（どちらも dBFS）。
        case level(Float, threshold: Float, isSpeaking: Bool)
        case failed(String)
    }

    let events: AsyncStream<Event>

    private let analyzer: SpeechAnalyzer
    private let audio: Mutex<AudioState>
    private let audioInput: AsyncStream<AnalyzerInput>.Continuation
    private let signalInput: AsyncStream<VoiceSignal>.Continuation
    private let eventOutput: AsyncStream<Event>.Continuation
    private let consumers: [Task<Void, Never>]
    private let ticker: Task<Void, Never>

    fileprivate static let logger = Logger(subsystem: "jp.hibiki.OdaiAttack", category: "Speech")

    private init(
        events: AsyncStream<Event>,
        analyzer: SpeechAnalyzer,
        converter: sending AnalyzerInputConverter,
        audioInput: AsyncStream<AnalyzerInput>.Continuation,
        signalInput: AsyncStream<VoiceSignal>.Continuation,
        eventOutput: AsyncStream<Event>.Continuation,
        consumers: [Task<Void, Never>],
        ticker: Task<Void, Never>
    ) {
        self.events = events
        self.analyzer = analyzer
        self.audio = Mutex(AudioState(converter: converter))
        self.audioInput = audioInput
        self.signalInput = signalInput
        self.eventOutput = eventOutput
        self.consumers = consumers
        self.ticker = ticker
    }

    /// 日本語の認識を準備して始める。初めて使うときは音声モデルのダウンロードが入ることがある。
    static func make(onModelDownload: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> SpeechWordRecognizer {
        let clock = ContinuousClock()
        let start = clock.now
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")) else {
            throw SpeechRecognitionError.japaneseUnsupported
        }
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [.shortForm],
            transcriptionOptions: [],
            // frequentFinalization が無いと、finalize(through:) を呼んでも確定した結果が届かない（Mac で確認）
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: [.audioTimeRange]
        )
        // 必要なら音声モデルをダウンロードする（言語の予約も兼ねる）
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let progress = request.progress
            let reporter = Task {
                while !Task.isCancelled {
                    onModelDownload(progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { reporter.cancel() }
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]))
        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])

        let (events, eventOutput) = AsyncStream<Event>.makeStream()
        let (audioStream, audioInput) = AsyncStream<AnalyzerInput>.makeStream()
        let (signals, signalInput) = AsyncStream<VoiceSignal>.makeStream()
        try await analyzer.start(inputSequence: audioStream)

        let segmenter = Segmenter(analyzer: analyzer) { eventOutput.yield($0) }
        let results = Task {
            do {
                for try await result in transcriber.results {
                    await segmenter.handle(result)
                }
            } catch {
                logger.error("音声認識が止まりました: \(error.localizedDescription, privacy: .public)")
                eventOutput.yield(.failed("音声認識が止まりました: \(SpeechRecognitionError.describe(error))"))
            }
        }
        let signalHandler = Task {
            for await signal in signals {
                await segmenter.handle(signal)
            }
        }
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                await segmenter.tick()
            }
        }
        logger.info("音声認識の準備 \((clock.now - start).inMilliseconds, format: .fixed(precision: 0)) ms")

        return SpeechWordRecognizer(
            events: events,
            analyzer: analyzer,
            converter: converter,
            audioInput: audioInput,
            signalInput: signalInput,
            eventOutput: eventOutput,
            consumers: [results, signalHandler],
            ticker: ticker
        )
    }

    /// 音声を渡す。オーディオスレッドから呼んでよい（同時に複数のスレッドから呼ばないこと）。
    func append(_ buffer: AVReadOnlyAudioPCMBuffer) {
        let receivedAt = ContinuousClock.now
        audio.withLock { state in
            let sampleRate = buffer.format.sampleRate
            let frameCount = buffer.frameLength
            guard sampleRate > 0, frameCount > 0 else { return }
            // 形式は途中で変わることがある（オーディオの設定が変わって入れ直したとき）
            if state.loggedSampleRate != sampleRate {
                state.loggedSampleRate = sampleRate
                Self.logger.info("音声入力 \(sampleRate, format: .fixed(precision: 0)) Hz \(buffer.format.channelCount) ch、1回 \(Double(frameCount) / sampleRate * 1000, format: .fixed(precision: 0)) ms ずつ")
            }

            // 先に認識へ音声を渡す（このあと無音で確定を頼むとき、その時点までの音声が認識側に届いているように）
            do {
                for input in try state.converter.convert(AVAudioPCMBuffer(copying: buffer), at: nil) {
                    audioInput.yield(input)
                }
            } catch {
                Self.logger.error("音声の変換に失敗: \(error.localizedDescription, privacy: .public)")
            }

            // 短い区間ごとの音量で、話し始めと話し終わりを判定する
            var signals: [VoiceSignal] = []
            var loudest: Float = -160
            if case .float(let channel) = buffer.channelData(0) {
                let window = max(Int(sampleRate * SpeechTuning.levelWindow), 1)
                channel.withUnsafeBufferPointer { samples in
                    var offset = 0
                    while offset < frameCount {
                        let count = min(window, frameCount - offset)
                        let rms = vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: samples[offset..<offset + count]))
                        let level = 20 * log10(max(rms, 1e-8))
                        loudest = max(loudest, level)
                        offset += count
                        // この区間の終わりが、バッファを受け取った時刻より何秒前か
                        let secondsBeforeReceived = Double(frameCount - offset) / sampleRate
                        switch state.detector.process(level: level, duration: Double(count) / sampleRate) {
                        case .started:
                            signals.append(.started(at: receivedAt - .seconds(secondsBeforeReceived)))
                        case .ended(let silence):
                            signals.append(.ended(
                                at: receivedAt - .seconds(secondsBeforeReceived + silence),
                                audioTime: state.receivedSeconds + Double(offset) / sampleRate - silence
                            ))
                        case nil:
                            break
                        }
                    }
                }
            }
            state.receivedSeconds += Double(frameCount) / sampleRate

            for signal in signals {
                signalInput.yield(signal)
            }
            eventOutput.yield(.level(loudest, threshold: state.detector.threshold, isSpeaking: state.detector.isSpeaking))
        }
    }

    /// 音声の入力を終え、残りを確定させてから `events` を閉じる。
    func finish() async {
        let tail = audio.withLock { state in (try? state.converter.flush()) ?? [] }
        for input in tail {
            audioInput.yield(input)
        }
        audioInput.finish()
        signalInput.finish()
        ticker.cancel()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            Self.logger.error("認識を終えるときにエラー: \(error.localizedDescription, privacy: .public)")
        }
        for consumer in consumers {
            await consumer.value
        }
        eventOutput.finish()
    }
}

nonisolated enum SpeechRecognitionError: LocalizedError {
    case japaneseUnsupported
    case microphoneDenied
    case speechRecognitionDenied
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .japaneseUnsupported: "この端末は日本語の音声認識に対応していません"
        case .microphoneDenied: "マイクの使用が許可されていません。設定アプリの OdaiAttack から許可してください"
        case .speechRecognitionDenied: "音声認識の使用が許可されていません。設定アプリの OdaiAttack から許可してください"
        case .microphoneUnavailable: "マイクが使えません"
        }
    }

    /// 音声認識で起きたエラーを、画面に出す説明にする。
    static func describe(_ error: any Error) -> String {
        if let speechError = error as? SFSpeechError {
            switch speechError.code {
            case .noModel, .cannotAllocateUnsupportedLocale:
                // シミュレーターには音声入力用のモデルが無く、ここに来る
                return "日本語の音声認識モデルを用意できませんでした。ネットワークにつないで、もう一度試してください（シミュレーターでは使えないので実機で試してください）"
            case .insufficientResources:
                return "端末の空きが足りず、音声認識を始められませんでした"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

/// オーディオスレッドで使う状態。`SpeechWordRecognizer` の Mutex で守る。
private nonisolated struct AudioState {
    let converter: AnalyzerInputConverter
    var detector = VoiceActivityDetector()
    /// これまでに受け取った音声の長さ（秒）。認識側の時間軸（最初の音声からの秒数）と同じ。
    /// サンプルレートが途中で変わっても合うように、フレーム数ではなく秒で持つ。
    var receivedSeconds = 0.0
    var loggedSampleRate: Double?
}

/// オーディオスレッドから `Segmenter` へ送る、話し始め・話し終わりの知らせ。
private nonisolated enum VoiceSignal: Sendable {
    case started(at: ContinuousClock.Instant)
    /// `audioTime` は認識側の時間軸での話し終わり（秒）。
    case ended(at: ContinuousClock.Instant, audioTime: Double)
}

private nonisolated struct FinalizeRequest: Sendable {
    /// ここまでの音声を確定させる。nil なら受け取った音声すべて。
    let through: CMTime?
    let speechEndedAt: ContinuousClock.Instant?
    let reason: String
}

/// 認識結果と、話し始め・話し終わりの知らせから、いつ認識を確定させるかを決める。
private actor Segmenter {
    private let analyzer: SpeechAnalyzer
    private let emit: @Sendable (SpeechWordRecognizer.Event) -> Void

    /// 認識中でまだ確定していない文字列と、それが最後に変わった時刻。
    private var partial = ""
    private var partialChangedAt: ContinuousClock.Instant?
    /// 話し始めた時刻（話し終わるまで）。
    private var speechStartedAt: ContinuousClock.Instant?
    /// 次に届く確定結果の話し終わりの時刻（無音で確定を頼んだとき）。
    private var speechEndedAt: ContinuousClock.Instant?
    private var pendingRequest: FinalizeRequest?
    private var isFinalizing = false

    init(analyzer: SpeechAnalyzer, emit: @escaping @Sendable (SpeechWordRecognizer.Event) -> Void) {
        self.analyzer = analyzer
        self.emit = emit
    }

    func handle(_ result: DictationTranscriber.Result) {
        guard result.isFinal else {
            setPartial(String(result.text.characters))
            return
        }
        let endedAt = speechEndedAt
        speechEndedAt = nil
        setPartial("")

        let words = SpokenWords.split(result.text)
        guard !words.isEmpty else {
            SpeechWordRecognizer.logger.info("確定したが文字が無い（聞き取れなかったか、声ではない音）")
            return
        }
        let joined = words.joined(separator: " / ")
        if let endedAt {
            SpeechWordRecognizer.logger.info("確定 \(joined, privacy: .public)（話し終わりから \((ContinuousClock.now - endedAt).inMilliseconds, format: .fixed(precision: 0)) ms）")
        } else {
            SpeechWordRecognizer.logger.info("確定 \(joined, privacy: .public)")
        }
        emit(.words(words, speechEndedAt: endedAt))
    }

    func handle(_ signal: VoiceSignal) async {
        switch signal {
        case .started(let at):
            speechStartedAt = at
        case .ended(let at, let audioTime):
            speechStartedAt = nil
            let through = CMTime(seconds: audioTime + SpeechTuning.finalizeMargin, preferredTimescale: 1000)
            await finalize(FinalizeRequest(through: through, speechEndedAt: at, reason: "無音"))
        }
    }

    /// 無音で区切れなかったときの予備。定期的に呼ぶ。
    func tick() async {
        let now = ContinuousClock.now
        if let changedAt = partialChangedAt, now - changedAt >= .seconds(SpeechTuning.stableTextFallback) {
            partialChangedAt = nil
            await finalize(FinalizeRequest(through: nil, speechEndedAt: nil, reason: "文字列が変わらない"))
        } else if let startedAt = speechStartedAt, now - startedAt >= .seconds(SpeechTuning.maxSegmentDuration) {
            speechStartedAt = now
            await finalize(FinalizeRequest(through: nil, speechEndedAt: nil, reason: "長く話し続けている"))
        }
    }

    private func setPartial(_ text: String) {
        guard text != partial else { return }
        partial = text
        partialChangedAt = text.isEmpty ? nil : .now
        emit(.partial(text))
    }

    /// 認識の確定を頼む。確定の途中で次の依頼が来たら、終わってからいちばん新しい依頼を実行する。
    private func finalize(_ request: FinalizeRequest) async {
        pendingRequest = request
        guard !isFinalizing else { return }
        isFinalizing = true
        while let next = pendingRequest {
            pendingRequest = nil
            speechEndedAt = next.speechEndedAt
            SpeechWordRecognizer.logger.debug("確定を依頼（\(next.reason, privacy: .public)）")
            do {
                try await analyzer.finalize(through: next.through)
            } catch {
                SpeechWordRecognizer.logger.error("確定に失敗（\(next.reason, privacy: .public)）: \(error.localizedDescription, privacy: .public)")
            }
        }
        isFinalizing = false
    }
}
