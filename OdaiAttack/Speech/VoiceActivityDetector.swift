//
//  VoiceActivityDetector.swift
//  OdaiAttack
//

import Foundation

/// 音量から、話し始めと話し終わりを判定する。しきい値は周りの騒音レベルに合わせて動かす。
nonisolated struct VoiceActivityDetector {
    enum Change: Equatable {
        case started
        /// 話し終わった。`silence` は、話し終わってから判定するまでに続いた無音の長さ（秒）。
        case ended(silence: Double)
    }

    private(set) var isSpeaking = false
    private var noiseFloor: Float?
    private var loudDuration = 0.0
    private var quietDuration = 0.0

    /// 話し始めとみなす音量（dBFS）。
    var threshold: Float {
        max((noiseFloor ?? SpeechTuning.minimumSpeechDB) + SpeechTuning.speechMarginDB, SpeechTuning.minimumSpeechDB)
    }

    /// 今のしきい値。話している間は `speechHysteresisDB` だけ下げる。
    private var currentThreshold: Float {
        isSpeaking ? threshold - SpeechTuning.speechHysteresisDB : threshold
    }

    /// 長さ `duration` 秒の区間の音量 `level`（dBFS）を渡す。話し始め・話し終わりが決まった区間で値を返す。
    mutating func process(level: Float, duration: Double) -> Change? {
        // 騒音レベルは、下がるときはすぐに、上がるときはゆっくり追いかける（最初の区間で初期化）
        if let floor = noiseFloor, level > floor {
            noiseFloor = floor + (level - floor) * Float(min(duration / SpeechTuning.noiseFloorRiseTime, 1))
        } else {
            noiseFloor = level
        }

        if level >= currentThreshold {
            loudDuration += duration
            quietDuration = 0
            if !isSpeaking, loudDuration >= SpeechTuning.speechStartDuration {
                isSpeaking = true
                return .started
            }
        } else {
            quietDuration += duration
            loudDuration = 0
            if isSpeaking, quietDuration >= SpeechTuning.silenceToEndWord {
                isSpeaking = false
                return .ended(silence: quietDuration)
            }
        }
        return nil
    }
}
