//
//  AudioIO.swift
//  OdaiAttack
//

import AVFoundation
import Speech
import Synchronization
import os

/// マイクの入力と効果音の出力。
///
/// 効果音を鳴らしながら聞くので、同じ AVAudioEngine で扱い、音声処理（エコーキャンセル）を有効にする。
/// 音声処理は端末から出した音をマイクの入力から取り除くので、効果音が言葉として認識されにくくなる。
///
/// 入出力のサンプルレートなどが変わると、エンジンは自分で止まって `AVAudioEngineConfigurationChange` を出す。
/// 初めて音声処理を有効にしたときに起き、そのままだとインストール直後の1回目だけ音声が入らなかった。
/// 止まったら、タップを今の形式で付け直して動かし直す。
final class AudioIO {
    /// 聞き始めてからこの時間たっても音声が届かなければ、1回だけ入れ直す。
    private static let audioArrivalTimeout: Duration = .seconds(1)

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [SoundEffect: AVAudioPCMBuffer] = [:]
    private var isStarted = false
    /// 音声を渡している相手。聞いていないときは nil。
    private var captureTarget: SpeechWordRecognizer?
    /// タップが受け取ったバッファの数（オーディオスレッドで数える）。
    private let receivedBuffers = BufferCounter()
    private var configurationObserver: (any NSObjectProtocol)?
    private var arrivalCheck: Task<Void, Never>?

    private static let logger = Logger(subsystem: "jp.hibiki.OdaiAttack", category: "Audio")

    /// マイクと音声認識の使用許可を求める。まだ決めていなければ確認のダイアログが出る。
    @concurrent nonisolated static func requestPermissions() async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw SpeechRecognitionError.microphoneDenied
        }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw SpeechRecognitionError.speechRecognitionDenied
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// 音声セッションとエンジンを始める。このあと効果音を鳴らせる。
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // measurement は入力の自動調整を切るモード。音声処理を使うときは組み合わせず、default にする
        let mode: AVAudioSession.Mode = SpeechTuning.usesVoiceProcessing ? .default : .measurement
        try session.setCategory(.playAndRecord, mode: mode, options: [.defaultToSpeaker])
        try session.setActive(true)

        // 音声処理の切り替えはエンジンが止まっているときしかできない。使えない端末でも、音声処理なしで続ける
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled != SpeechTuning.usesVoiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(SpeechTuning.usesVoiceProcessing)
            } catch {
                Self.logger.error("音声処理を切り替えられませんでした: \(error.localizedDescription, privacy: .public)")
            }
        }
        if player.engine == nil {
            engine.attach(player)
            try engine.connectNode(player, to: engine.mainMixerNode, format: SoundEffect.format)
        }
        if buffers.isEmpty {
            for effect in SoundEffect.allCases {
                buffers[effect] = effect.makeBuffer()
            }
        }
        if configurationObserver == nil {
            // 通知はエンジン内部のキューから来るので、メインで受ける
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.restart(reason: "オーディオの設定が変わってエンジンが止まった")
                }
            }
        }
        engine.prepare()
        try engine.start()
        try player.playAudio()
        isStarted = true
        let format = input.outputFormat(forBus: 0)
        Self.logger.info("オーディオ開始: マイク \(format.sampleRate, format: .fixed(precision: 0)) Hz \(format.channelCount) ch、音声処理 \(input.isVoiceProcessingEnabled ? "あり" : "なし", privacy: .public)")
    }

    /// マイクの音声を `recognizer` に流し始める。
    func startCapture(feeding recognizer: SpeechWordRecognizer) throws {
        try installTap(feeding: recognizer)
        captureTarget = recognizer
        checkAudioArrival()
    }

    /// マイクの音声が安定して届くまで待つ（`buffers` 個のバッファ = 1個 100 ms）。
    /// 初めて音声処理を有効にしたときはエンジンが一度止まって動かし直すので、その前に効果音を鳴らすと鳴らない。
    /// `timeout` が過ぎたら、届いていなくても戻る。
    func waitForSteadyInput(buffers count: Int = 5, timeout: Duration = .seconds(3)) async throws {
        let countAtStart = receivedBuffers.value
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while receivedBuffers.value - countAtStart < count {
            guard clock.now < deadline else {
                Self.logger.error("\(timeout.roundedMilliseconds, privacy: .public) ms 待っても、マイクの音声が安定して届かない（届いたバッファ \(self.receivedBuffers.value - countAtStart) 個）")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func stopCapture() {
        arrivalCheck?.cancel()
        arrivalCheck = nil
        guard captureTarget != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        captureTarget = nil
    }

    /// 効果音を鳴らす。前の効果音が鳴っている間は、その後に続けて鳴らす。
    func play(_ effect: SoundEffect) {
        guard engine.isRunning, let buffer = buffers[effect] else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    func stop() {
        stopCapture()
        isStarted = false
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 入力の今の形式でタップを付ける。
    private func installTap(feeding recognizer: SpeechWordRecognizer) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechRecognitionError.microphoneUnavailable
        }
        let counter = receivedBuffers
        // タップのバッファは 100〜400 ms の範囲でしか指定できない。区切りの遅れを小さくするため、いちばん短い 100 ms にする
        try input.installAudioTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { buffer, _ in
            counter.increment()
            recognizer.append(buffer)
        }
    }

    /// 聞き始めて少したっても音声が届かなければ、1回だけ入れ直す（止まった知らせが来なかったとき用）。
    private func checkAudioArrival() {
        let countAtStart = receivedBuffers.value
        arrivalCheck?.cancel()
        arrivalCheck = Task { [weak self] in
            try? await Task.sleep(for: Self.audioArrivalTimeout)
            guard !Task.isCancelled, let self, self.captureTarget != nil, self.receivedBuffers.value == countAtStart else { return }
            self.restart(reason: "聞き始めて \(Self.audioArrivalTimeout.roundedMilliseconds) ms たっても音声が届かない")
        }
    }

    /// エンジンを止めてから、タップを今の形式で付け直して動かし直す。
    private func restart(reason: String) {
        guard isStarted else { return }
        Self.logger.info("オーディオを動かし直す（\(reason, privacy: .public)）。エンジンは\(self.engine.isRunning ? "動いていた" : "止まっていた", privacy: .public)")
        engine.stop()
        do {
            if let captureTarget {
                engine.inputNode.removeTap(onBus: 0)
                try installTap(feeding: captureTarget)
            }
            engine.prepare()
            try engine.start()
            try player.playAudio()
        } catch {
            Self.logger.error("オーディオを動かし直せませんでした: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// タップのコールバック（オーディオスレッド）から数え、メインから読む。
nonisolated final class BufferCounter: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    func increment() {
        count.withLock { $0 += 1 }
    }
}
