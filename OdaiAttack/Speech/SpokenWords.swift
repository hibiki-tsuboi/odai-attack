//
//  SpokenWords.swift
//  OdaiAttack
//

import CoreMedia
import Foundation
import Speech

/// 確定した認識結果を言葉に分けたり、同じ言葉かどうかを比べたりする。
nonisolated enum SpokenWords {
    /// 確定した認識結果を言葉に分ける。単語と単語の間が `SpeechTuning.wordGap` 以上空いていたら別の言葉にする
    /// （無音での区切りが間に合わず、2語が1つの結果に入ったとき用）。
    static func split(_ text: AttributedString) -> [String] {
        var words: [String] = []
        var current = ""
        var previousEnd: Double?
        for run in text.runs {
            if let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] {
                if let previousEnd, CMTimeGetSeconds(range.start) - previousEnd >= SpeechTuning.wordGap {
                    words.append(current)
                    current = ""
                }
                previousEnd = CMTimeGetSeconds(range.end)
            }
            current += String(text[run.range].characters)
        }
        words.append(current)
        return words
            .flatMap { $0.split(whereSeparator: { "、。,.".contains($0) }).map(String.init) }
            .map(clean)
            .filter { !$0.isEmpty }
    }

    /// 前後の空白・句読点・記号を取り除く。
    static func clean(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
    }

    /// 同じ言葉かどうかを比べるためのキー。ひらがなとカタカナ、全角と半角、大文字と小文字の違いを無視する。
    static func duplicateKey(_ word: String) -> String {
        let folded = clean(word).precomposedStringWithCompatibilityMapping.lowercased()
        return folded.applyingTransform(.hiraganaToKatakana, reverse: true) ?? folded
    }
}
