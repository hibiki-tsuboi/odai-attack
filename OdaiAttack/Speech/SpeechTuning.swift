//
//  SpeechTuning.swift
//  OdaiAttack
//

import Foundation

/// 声を言葉に区切るためのパラメータ。実機で試しながら調整する。
nonisolated enum SpeechTuning {
    // MARK: マイク

    /// マイクの音声処理（エコーキャンセル・雑音除去・音量の自動調整）を使う。
    /// 効果音がマイクに入って言葉として認識されないようにするため。認識や区切りが悪くなるなら false にして比べる。
    static let usesVoiceProcessing = true

    // MARK: 無音で区切る（ふだんはこれで確定する）

    /// この長さ静かになったら、1語を言い終えたとみなして確定する（秒）。
    /// 短いほど速く確定するが、「ロケット」の「ッ」のような言葉の中の無音で切れやすくなる。
    static let silenceToEndWord = 0.25
    /// 確定するとき、発話の終わりからこの長さ後ろまでの音声を含める（秒）。`silenceToEndWord` より短くする。
    static let finalizeMargin = 0.1
    /// この長さ続けて音量がしきい値を超えたら、話し始めたとみなす（秒）。
    static let speechStartDuration = 0.04
    /// 周りの騒音レベルよりこれだけ大きい音を声とみなす（dB）。
    static let speechMarginDB: Float = 12
    /// 話している間は、声とみなすしきい値をこれだけ下げる（dB）。騒がしいとき、言葉の途中の小さい音で切れないように。
    static let speechHysteresisDB: Float = 6
    /// 声とみなす音量の下限（dBFS）。静かな部屋で小さな物音を拾わないため。
    static let minimumSpeechDB: Float = -50
    /// 騒音レベルが上がったとき、この時間をかけて追いつく（秒）。下がったときはすぐに追いつく。
    static let noiseFloorRiseTime = 8.0
    /// 音量を測る区間の長さ（秒）。
    static let levelWindow = 0.02

    // MARK: 無音で区切れなかったときの予備

    /// 認識中の文字列がこの長さ変わらなければ確定する（秒）。騒がしくて無音を検出できないとき用。
    static let stableTextFallback = 0.8
    /// 話し続けてこの長さを超えたら、途中でも確定する（秒）。
    static let maxSegmentDuration = 3.0

    // MARK: 確定した文字列を言葉に分ける

    /// 確定した文字列の中で、単語と単語の間がこれ以上空いていたら別の言葉として分ける（秒）。
    static let wordGap = 0.15
}
