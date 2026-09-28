//
//  AudioIO.swift
//  OdaiAttack
//

import AVFoundation
import Speech
import os

/// マイクの入力と効果音の出力。
///
/// 効果音を鳴らしながら聞くので、同じ AVAudioEngine で扱い、音声処理（エコーキャンセル）を有効にする。
/// 音声処理は端末から出した音をマイクの入力から取り除くので、効果音が言葉として認識されにくくなる。
nonisolated final class AudioIO {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [SoundEffect: AVAudioPCMBuffer] = [:]
    private var isCapturing = false

    private static let logger = Logger(subsystem: "jp.hibiki.OdaiAttack", category: "Audio")

    /// マイクと音声認識の使用許可を求める。まだ決めていなければ確認のダイアログが出る。
    @concurrent static func requestPermissions() async throws {
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
        engine.prepare()
        try engine.start()
        try player.playAudio()
    }

    /// マイクの音声を `recognizer` に流し始める。
    func startCapture(feeding recognizer: SpeechWordRecognizer) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechRecognitionError.microphoneUnavailable
        }
        // タップのバッファは 100〜400 ms の範囲でしか指定できない。区切りの遅れを小さくするため、いちばん短い 100 ms にする
        try input.installAudioTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { buffer, _ in
            recognizer.append(buffer)
        }
        isCapturing = true
    }

    func stopCapture() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        isCapturing = false
    }

    /// 効果音を鳴らす。前の効果音が鳴っている間は、その後に続けて鳴らす。
    func play(_ effect: SoundEffect) {
        guard engine.isRunning, let buffer = buffers[effect] else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    func stop() {
        stopCapture()
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
