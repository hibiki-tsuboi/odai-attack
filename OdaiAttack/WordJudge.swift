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

    /// 言葉がお題に当てはまるか（Noul）。質問文は「判定のしくみ」画面にもそのまま出す。
    static let fitsTopicInstructions = "Is `word` a valid answer for the word-game category `topic`?"
    static let fitsTopicCriteria = NoulCriteria(
        yes: "`word` is something that belongs to `topic` or typically has the quality that `topic` describes. A surprising answer still counts if it genuinely fits.",
        no: "`word` does not fit `topic`, fits only in rare special cases, or is not a meaningful word."
    )
    /// どれくらい定番の答えか（Score）。段階は `typicalityLevels`。
    static let typicalityInstructions = "How typical an answer is `word` for the word-game category `topic`?"

    private static let fitsTopicID = "fits_topic"
    private static let typicalityID = "typicality"

    // 2つの質問は同じ state に対して並列に評価されるので、1リクエストにまとめて送る。
    private static let questions: [String: JevQuestion] = [
        fitsTopicID: .noul(instructions: fitsTopicInstructions, criteria: fitsTopicCriteria),
        typicalityID: .score(instructions: typicalityInstructions, levels: typicalityLevels.map(\.criterion)),
    ]

    private static let bestAnswerID = "best_answer"
    /// ベスト回答を選ぶ質問（Choice）。選択肢は正解した言葉。1語ずつの「意外さ」なら Score の典型度でわかるので、
    /// ここでは言葉どうしを見比べて、お題によく合っていて思いつく人が少ないものを1つ選ばせる。
    /// 文を変えたら、proxy/src/validate.ts の制限（500文字まで）に収まるか確かめる。
    static let bestAnswerInstructions = "Which answer is the best answer of this round for the word-game category `topic`? The best answer fits `topic` well, and few players would think of it."

    /// 言葉の判定のタイムアウトと再試行。ゲームの結果を早く出したいので、1回を短めに切って1回だけ送り直す。
    /// （TypeSafe が混んでいると数秒〜10秒以上かかる応答が混ざるが、送り直すと速く返ることが多い）
    static let judgmentRetry = JevRetryPolicy(maxAttempts: 2, attemptTimeout: 4, initialBackoff: 0.3, maxBackoff: 1)
    /// ベスト回答のタイムアウトと再試行。急がないので、公式 SDK の既定値（1回10秒、0.5秒から倍々で2回まで）に合わせる。
    static let bestAnswerRetry = JevRetryPolicy(maxAttempts: 3, attemptTimeout: 10, initialBackoff: 0.5, maxBackoff: 5)

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

        let (response, latency) = try await send(request, retry: Self.judgmentRetry, label: "\(topic) / \(word)")

        guard case let .noul(fitProbability)? = response.answers[Self.fitsTopicID] else {
            throw JevError.missingAnswer(questionID: Self.fitsTopicID)
        }
        guard case let .score(typicality)? = response.answers[Self.typicalityID] else {
            throw JevError.missingAnswer(questionID: Self.typicalityID)
        }
        let level = typicality.mostLikelyLevel ?? Int(typicality.score.rounded())
        let levelProbabilities = (0...Self.maxTypicality).map { typicality.probabilities[String($0)] ?? 0 }

        Self.logger.info("Jev \(latency.inMilliseconds, format: .fixed(precision: 0)) ms [\(response.model, privacy: .public)] \(topic, privacy: .public) / \(word, privacy: .public): noul=\(fitProbability, format: .fixed(precision: 2)) score=\(typicality.score, format: .fixed(precision: 2)) input_tokens=\(response.usage.inputTokens)")

        return WordJudgment(
            topic: topic,
            word: word,
            fitProbability: fitProbability,
            typicality: typicality.score,
            typicalityConfidence: typicality.confidence,
            typicalityLevel: min(max(level, 0), Self.maxTypicality),
            typicalityProbabilities: levelProbabilities,
            latency: latency,
            model: response.model,
            inputTokens: response.usage.inputTokens
        )
    }

    /// 正解した言葉（2つ以上）の中から、このラウンドのベスト回答を1つ選ぶ。
    func bestAnswer(among words: [String], topic: String) async throws -> BestAnswer {
        let options = Dictionary(words.map { ($0, String?.none) }, uniquingKeysWith: { first, _ in first })
        let request = SystemOneRequest(
            model: Self.model,
            state: ["topic": topic],
            questions: [Self.bestAnswerID: .choice(instructions: Self.bestAnswerInstructions, options: options)]
        )
        let (response, latency) = try await send(request, retry: Self.bestAnswerRetry, label: "\(topic) のベスト回答")

        guard case let .choice(answer)? = response.answers[Self.bestAnswerID] else {
            throw JevError.missingAnswer(questionID: Self.bestAnswerID)
        }
        // 確率の高い順。Jev が選んだもの（いちばん確率が高い）を先頭にする
        let candidates = answer.probabilities
            .map { BestAnswer.Candidate(word: $0.key, probability: $0.value) }
            .sorted { ($0.word == answer.choice ? 1 : 0, $0.probability) > ($1.word == answer.choice ? 1 : 0, $1.probability) }

        Self.logger.info("Jev \(latency.inMilliseconds, format: .fixed(precision: 0)) ms [\(response.model, privacy: .public)] \(topic, privacy: .public) のベスト回答（\(words.count) 語から）: \(answer.choice, privacy: .public) confidence=\(answer.confidence, format: .fixed(precision: 2))")

        return BestAnswer(candidates: candidates, confidence: answer.confidence, latency: latency)
    }

    /// リクエストを送り、かかった時間（再試行した分も含む）も返す。失敗したときもかかった時間をログに出す。
    private func send<State: Encodable & Sendable>(
        _ request: SystemOneRequest<State>,
        retry: JevRetryPolicy,
        label: String
    ) async throws -> (response: SystemOneResponse, latency: Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let response = try await client.systemOne(request, retry: retry)
            return (response, clock.now - start)
        } catch {
            Self.logger.error("Jev 失敗 \((clock.now - start).inMilliseconds, format: .fixed(precision: 0)) ms \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

/// ラウンドのベスト回答。正解した言葉の中から Jev が選ぶ。
nonisolated struct BestAnswer: Equatable, Sendable {
    nonisolated struct Candidate: Equatable, Sendable {
        let word: String
        let probability: Double
    }

    /// 選択肢（正解した言葉）と、それぞれが選ばれる確率。確率の高い順で、先頭がベスト回答。
    let candidates: [Candidate]
    /// 確率が1つの言葉に集中しているほど 1 に近い。低いほど僅差。
    let confidence: Double
    let latency: Duration

    var word: String { candidates.first?.word ?? "" }
    /// 2番目に確率の高かった言葉。
    var runnerUp: String? { candidates.dropFirst().first?.word }
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
    /// 典型度の段階ごとの確率（`WordJudge.typicalityLevels` の順）。
    let typicalityProbabilities: [Double]
    /// `JevClient` の呼び出しにかかった時間（JSON の変換と通信、再試行した分を含む）。
    let latency: Duration
    /// 実際に回答したモデル（例: "jev-1.13.0"）。
    let model: String
    let inputTokens: Int

    var typicalityLabel: String { WordJudge.typicalityLevels[typicalityLevel].label }
}
