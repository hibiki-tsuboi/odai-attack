//
//  SystemOneAPI.swift
//  OdaiAttack
//

import Foundation

// TypeSafe System One API（POST /v1/systemone）のリクエストとレスポンス。
// 形式は https://docs.typesafe.ai/api に合わせている。

nonisolated struct SystemOneRequest<State: Encodable & Sendable>: Encodable, Sendable {
    var model: String
    var state: State
    /// キーは質問 ID。ID はモデルに送られないので、質問の意味はすべて `instructions` と `criteria` に書く。
    var questions: [String: JevQuestion]
}

nonisolated enum JevQuestion: Encodable, Sendable {
    /// yes/no の質問。答えは yes の確率（0〜1）。
    case noul(instructions: String, criteria: NoulCriteria? = nil)
    /// 順序のある段階で評価する質問。`levels` は低い段階から順に並べる（2〜10個）。
    case score(instructions: String, levels: [String])
    /// 選択肢から1つ選ぶ質問。キーが選択肢の名前（モデルにも送られる）で、値はその説明（無ければ nil）。
    case choice(instructions: String, options: [String: String?])

    private enum CodingKeys: String, CodingKey {
        case type, instructions, criteria
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .noul(instructions, criteria):
            try container.encode("noul", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            try container.encodeIfPresent(criteria, forKey: .criteria)
        case let .score(instructions, levels):
            try container.encode("score", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            try container.encode(levels, forKey: .criteria)
        case let .choice(instructions, options):
            try container.encode("choice", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            try container.encode(options, forKey: .criteria)
        }
    }
}

nonisolated struct NoulCriteria: Encodable, Sendable {
    /// yes（1 に近い値）が意味すること。
    var yes: String
    /// no（0 に近い値）が意味すること。
    var no: String

    private enum CodingKeys: String, CodingKey {
        case yes = "true"
        case no = "false"
    }
}

nonisolated struct SystemOneResponse: Decodable, Sendable {
    /// 実際に回答したモデルのバージョン付き ID（例: "jev-1.13.0"）。
    let model: String
    /// リクエストと同じ質問 ID をキーにした回答。
    let answers: [String: JevAnswer]
    let usage: JevUsage
}

nonisolated struct JevUsage: Decodable, Sendable {
    let inputTokens: Int
    let outputTokens: Int

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

nonisolated enum JevAnswer: Decodable, Sendable {
    /// yes の確率（0〜1）。
    case noul(Double)
    case score(ScoreAnswer)
    case choice(ChoiceAnswer)
    /// このアプリでまだ扱っていない型。
    case unsupported(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, noul
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "noul":
            self = .noul(try container.decode(Double.self, forKey: .noul))
        case "score":
            self = .score(try ScoreAnswer(from: decoder))
        case "choice":
            self = .choice(try ChoiceAnswer(from: decoder))
        default:
            self = .unsupported(type: type)
        }
    }
}

nonisolated struct ScoreAnswer: Decodable, Sendable {
    /// 段階番号を確率で重み付けした平均。0〜(段階数 - 1) の範囲で、段階の間の値にもなる。
    let score: Double
    /// 確率が1つの段階に集中しているほど 1 に近い。
    let confidence: Double
    /// 段階番号（"0", "1", ...）ごとの確率。
    let probabilities: [String: Double]

    /// 最も確率の高い段階の番号。
    var mostLikelyLevel: Int? {
        probabilities
            .compactMap { key, probability in Int(key).map { (level: $0, probability: probability) } }
            .max { $0.probability < $1.probability }?
            .level
    }
}

nonisolated struct ChoiceAnswer: Decodable, Sendable {
    /// いちばん確率の高い選択肢。
    let choice: String
    /// 確率が1つの選択肢に集中しているほど 1 に近い。
    let confidence: Double
    /// 選択肢ごとの確率。
    let probabilities: [String: Double]
}
