//
//  JudgeLabModel.swift
//  OdaiAttack
//

import Foundation
import Observation

/// 判定テスト画面（フェーズ1）の状態と操作。
@Observable
final class JudgeLabModel {
    static let benchmarkRuns = 10

    var topic = "赤いもの"
    var word = "りんご"

    private(set) var latest: WordJudgment?
    /// 新しい順。連続判定の結果は入れない。
    private(set) var history: [WordJudgment] = []
    private(set) var benchmark: LatencyBenchmark?
    /// 連続判定で何回目を実行中か。連続判定中以外は nil。
    private(set) var benchmarkRun: Int?
    private(set) var isRunning = false
    private(set) var errorMessage: String?

    /// API キーが設定されていないと nil。
    private let judge: WordJudge?

    init(client: (any JevClient)? = DirectJevClient.fromInfoPlist()) {
        judge = client.map { WordJudge(client: $0) }
    }

    var isAPIKeyMissing: Bool { judge == nil }

    var canRun: Bool {
        judge != nil && !isRunning && !trimmedTopic.isEmpty && !trimmedWord.isEmpty
    }

    func judgeOnce() async {
        guard canRun, let judge else { return }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }

        do {
            let judgment = try await judge.judge(word: trimmedWord, topic: trimmedTopic)
            latest = judgment
            history.insert(judgment, at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 同じお題と言葉で続けて判定し、レイテンシの最小・平均・最大を出す。
    /// 1回ずつ順番に送る（同時に送ると互いの待ち時間が混ざるため）。
    func runBenchmark() async {
        guard canRun, let judge else { return }
        let topic = trimmedTopic
        let word = trimmedWord
        isRunning = true
        errorMessage = nil
        benchmark = nil
        defer {
            isRunning = false
            benchmarkRun = nil
        }

        var latencies: [Duration] = []
        for run in 1...Self.benchmarkRuns {
            benchmarkRun = run
            do {
                let judgment = try await judge.judge(word: word, topic: topic)
                latest = judgment
                latencies.append(judgment.latency)
            } catch {
                errorMessage = "\(run)回目で失敗しました: \(error.localizedDescription)"
                return
            }
        }
        benchmark = LatencyBenchmark(topic: topic, word: word, latencies: latencies)
    }

    private var trimmedTopic: String { topic.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedWord: String { word.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// 連続判定のレイテンシ。`latencies` は実行した順。
nonisolated struct LatencyBenchmark: Sendable {
    let topic: String
    let word: String
    let latencies: [Duration]

    var min: Duration { latencies.min() ?? .zero }
    var max: Duration { latencies.max() ?? .zero }
    var average: Duration {
        latencies.isEmpty ? .zero : latencies.reduce(.zero, +) / latencies.count
    }
}
