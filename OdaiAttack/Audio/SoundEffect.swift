//
//  SoundEffect.swift
//  OdaiAttack
//

import AVFoundation

/// ゲームの効果音。音はコードで作る。
nonisolated enum SoundEffect: CaseIterable {
    /// 正解（ピコン）
    case correct
    /// 不正解（ブッ）
    case wrong
    /// カウントダウン
    case tick
    /// スタート
    case start
    /// 時間切れ
    case timeUp

    static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    private var notes: [Note] {
        switch self {
        case .correct: [Note(frequency: 1568, duration: 0.08, decay: 10), Note(frequency: 2093, duration: 0.22, decay: 8)]
        case .wrong: [Note(frequency: 140, duration: 0.25, decay: 4, isBuzz: true, volume: 0.6)]
        case .tick: [Note(frequency: 880, duration: 0.1, decay: 20)]
        case .start: [Note(frequency: 1760, duration: 0.35, decay: 5)]
        case .timeUp: [Note(frequency: 784, duration: 0.18, decay: 6), Note(frequency: 523, duration: 0.45, decay: 4)]
        }
    }

    func makeBuffer() -> AVAudioPCMBuffer {
        let sampleRate = Self.format.sampleRate
        let frameCount = notes.reduce(0) { $0 + Int($1.duration * sampleRate) }
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = buffer.floatChannelData![0]
        var index = 0
        for note in notes {
            let count = Int(note.duration * sampleRate)
            for frame in 0..<count {
                let time = Double(frame) / sampleRate
                let phase = 2 * Double.pi * note.frequency * time
                var wave = sin(phase)
                if note.isBuzz {
                    // 奇数倍音を足して「ブッ」というこもった音にする
                    wave += sin(3 * phase) / 3 + sin(5 * phase) / 5
                }
                // 5 ms で立ち上げて減衰させ、最後の 10 ms で 0 にする（プチッという音を防ぐ）
                let attack = min(time / 0.005, 1)
                let release = min(Double(count - frame) / sampleRate / 0.01, 1)
                samples[index] = Float(wave * attack * release * exp(-time * note.decay) * note.volume)
                index += 1
            }
        }
        return buffer
    }
}

private nonisolated struct Note {
    let frequency: Double
    let duration: Double
    /// 大きいほど早く小さくなる。
    let decay: Double
    var isBuzz = false
    var volume = 0.5
}
