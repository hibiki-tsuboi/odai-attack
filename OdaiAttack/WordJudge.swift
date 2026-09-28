//
//  WordJudge.swift
//  OdaiAttack
//

import Foundation
import os

/// お題と言葉から Jev への質問を組み立て、回答を `WordJudgment` にまとめる。
///
/// 質問文は英語で書く（Jev の主な学習言語が英語のため）。お題と言葉は日本語のまま `state` に入れる。
nonisolated struct WordJudge: Sendable {
    /// 固定するモデルのバージョン。`jev-latest` は新リリースで答えが変わるので使わない。
    static let model = "jev-1.13.0"

    /// 典型度（Score）の段階。低い順に並べる。`label` は画面表示用、`criterion` が Jev に送る説明。
    static let typicalityLevels: [(label: String, criterion: String)] = [
        ("当てはまらない", "`word` does not fit `topic`."),
        ("意外", "`word` fits `topic`, but it is a surprising answer that few people would think of."),
        ("ふつう", "`word` fits `topic` and is a reasonable answer, but it is not one of the first answers that come to mind."),
        ("定番", "`word` is a textbook example of `topic`, one of the first answers most people would say."),
    ]
    static var maxTypicality: Int { typicalityLevels.count - 1 }

    private static let fitsTopicID = "fits_topic"
    private static let typicalityID = "typicality"

    // 2つの質問は同じ state に対して並列に評価されるので、1リクエストにまとめて送る。
    private static let questions: [String: JevQuestion] = [
        fitsTopicID: .noul(
            instructions: "Is `word` a valid answer for the word-game category `topic`?",
            criteria: NoulCriteria(
                yes: "`word` is something that belongs to `topic` or typically has the quality that `topic` describes. A surprising answer still counts if it genuinely fits.",
                no: "`word` does not fit `topic`, fits only in rare special cases, or is not a meaningful word."
            )
        ),
        typicalityID: .score(
            instructions: "How typical an answer is `word` for the word-game category `topic`?",
            levels: typicalityLevels.map(\.criterion)
        ),
    ]

    private static let logger = Logger(subsystem: "jp.hibiki.OdaiAttack", category: "Jev")

    private let client: any JevClient

    init(client: any JevClient) {
        self.client = client
    }

    func judge(word: String, topic: String) async throws -> WordJudgment {
        let request = SystemOneRequest(
            model: Self.model,
            state: ["topic": topic, "word": word],
            questions: Self.questions
        )

        let clock = ContinuousClock()
        let start = clock.now
        let response: SystemOneResponse
        do {
            response = try await client.systemOne(request)
        } catch {
            let elapsed = clock.now - start
            Self.logger.error("Jev 失敗 \(elapsed.inMilliseconds, format: .fixed(precision: 0)) ms \(topic, privacy: .public) / \(word, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let latency = clock.now - start

        guard case let .noul(fitProbability)? = response.answers[Self.fitsTopicID] else {
            throw JevError.missingAnswer(questionID: Self.fitsTopicID)
        }
        guard case let .score(typicality)? = response.answers[Self.typicalityID] else {
            throw JevError.missingAnswer(questionID: Self.typicalityID)
        }
        let level = typicality.mostLikelyLevel ?? Int(typicality.score.rounded())

        Self.logger.info("Jev \(latency.inMilliseconds, format: .fixed(precision: 0)) ms [\(response.model, privacy: .public)] \(topic, privacy: .public) / \(word, privacy: .public): noul=\(fitProbability, format: .fixed(precision: 2)) score=\(typicality.score, format: .fixed(precision: 2)) input_tokens=\(response.usage.inputTokens)")

        return WordJudgment(
            topic: topic,
            word: word,
            fitProbability: fitProbability,
            typicality: typicality.score,
            typicalityConfidence: typicality.confidence,
            typicalityLevel: min(max(level, 0), Self.maxTypicality),
            latency: latency,
            model: response.model,
            inputTokens: response.usage.inputTokens
        )
    }
}

/// 1つの言葉をお題に照らして Jev で判定した結果。
nonisolated struct WordJudgment: Identifiable, Sendable {
    let id = UUID()
    let topic: String
    let word: String
    /// お題に当てはまる確率（Noul、0〜1）。
    let fitProbability: Double
    /// 典型度（Score、0〜`WordJudge.maxTypicality`）。段階の間の値にもなる。
    let typicality: Double
    /// 典型度の確率が1つの段階に集中しているほど 1 に近い。
    let typicalityConfidence: Double
    /// 最も確率の高い典型度の段階（`WordJudge.typicalityLevels` の番号）。
    let typicalityLevel: Int
    /// `JevClient` の呼び出しにかかった時間（JSON の変換と通信を含む）。
    let latency: Duration
    /// 実際に回答したモデル（例: "jev-1.13.0"）。
    let model: String
    let inputTokens: Int

    var typicalityLabel: String { WordJudge.typicalityLevels[typicalityLevel].label }
}
