//
//  JevClient.swift
//  OdaiAttack
//

import Foundation

/// Jev（TypeSafe System One API）の呼び出し口。実装を差し替えられるようにプロトコルにしている。
/// - `DirectJevClient`: TypeSafe API を直接呼ぶ（開発用）
/// - 将来: 自前の中継サーバー（Cloudflare Workers）経由の実装
nonisolated protocol JevClient: Sendable {
    func systemOne<State: Encodable & Sendable>(_ request: SystemOneRequest<State>) async throws -> SystemOneResponse
}

nonisolated enum JevError: LocalizedError {
    /// サーバーが 2xx 以外を返した。
    case http(status: Int, message: String?, requestID: String?)
    /// レスポンスに期待した型の回答が無かった。
    case missingAnswer(questionID: String)

    var errorDescription: String? {
        switch self {
        case let .http(status, message, requestID):
            let reason = switch status {
            case 401, 403: "API キーが無効か、設定されていません"
            case 422: "リクエストの形式が正しくありません"
            case 429: "リクエストが多すぎます（レート制限）。少し待ってから試してください"
            case 529: "TypeSafe が混雑しています。少し待ってから試してください"
            default: "サーバーでエラーが起きました"
            }
            var lines = ["\(reason)（HTTP \(status)）"]
            if let message { lines.append(message) }
            if let requestID { lines.append("request: \(requestID)") }
            return lines.joined(separator: "\n")
        case let .missingAnswer(questionID):
            return "レスポンスに質問 \(questionID) の回答がありません"
        }
    }
}
