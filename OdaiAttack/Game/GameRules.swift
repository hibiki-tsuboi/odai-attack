//
//  GameRules.swift
//  OdaiAttack
//

import Foundation

/// ゲームのルール。時間・正解のしきい値・点数はここで調整する。
nonisolated enum GameRules {
    /// 声で言える時間。
    static let roundDuration: Duration = .seconds(10)
    /// カウントダウンをいくつから始めるか（1秒ずつ）。
    static let countdownFrom = 3
    /// 時間切れの直前に言い始めた言葉を言い終えられるように、時間切れのあとも少しだけ聞く。
    static let endGrace: Duration = .milliseconds(400)
    /// 時間切れのあと、判定が終わっていない言葉をここまで待ってから結果を出す。
    static let judgmentWait: Duration = .seconds(2)

    /// 当てはまる確率（Noul）がこれ以上なら正解。
    static let correctThreshold = 0.5
    /// 正解1つの点数。
    static let pointsForCorrect = 1
    /// 意外な言葉のボーナス。典型度（Score、0〜3）が `maxTypicality` 以下なら `bonus` 点を足す。上から順に見る。
    /// 典型度が高い（定番の）言葉はボーナスなし。
    static let surpriseBonuses: [(maxTypicality: Double, bonus: Int)] = [
        (1.2, 2),
        (2.1, 1),
    ]

    enum Outcome: Equatable {
        case correct(bonus: Int)
        case wrong
        /// すでに言った言葉。
        case duplicate
        /// 判定が終わっていないか、失敗した。
        case unjudged

        var points: Int {
            if case .correct(let bonus) = self { GameRules.pointsForCorrect + bonus } else { 0 }
        }
    }

    static func outcome(for entry: SpokenEntry) -> Outcome {
        switch entry.status {
        case .duplicate:
            .duplicate
        case .judging, .failed:
            .unjudged
        case .judged(let judgment):
            judgment.fitProbability >= correctThreshold
                ? .correct(bonus: surpriseBonuses.first { judgment.typicality <= $0.maxTypicality }?.bonus ?? 0)
                : .wrong
        }
    }
}
