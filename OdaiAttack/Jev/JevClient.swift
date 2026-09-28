//
//  JevClient.swift
//  OdaiAttack
//

import Foundation

/// Jev（TypeSafe System One API）の呼び出し口。実装を差し替えられるようにプロトコルにしている。
/// - `ProxyJevClient`: 自前の中継サーバー（Cloudflare Workers）を通す。API キーはアプリに入らない
/// - `DirectJevClient`: TypeSafe API を直接呼ぶ（開発用）
nonisolated protocol JevClient: Sendable {
    /// 画面に出す接続先の名前。
    var connectionName: String { get }

    func systemOne<State: Encodable & Sendable>(_ request: SystemOneRequest<State>) async throws -> SystemOneResponse
}

/// Info.plist の設定から Jev の呼び出し口を作る。中継サーバーが設定されていればそれを使い、
/// 無ければ開発用に TypeSafe を直接呼ぶ（API キーが設定されているとき）。どちらも無ければ nil。
nonisolated func makeConfiguredJevClient(bundle: Bundle = .main) -> (any JevClient)? {
    if let proxy = ProxyJevClient.fromInfoPlist(bundle) {
        return proxy
    }
    return DirectJevClient.fromInfoPlist(bundle)
}

nonisolated enum JevError: LocalizedError {
    /// サーバー（TypeSafe か中継サーバー）が 2xx 以外を返した。
    case http(status: Int, message: String?, requestID: String?)
    /// レスポンスに期待した型の回答が無かった。
    case missingAnswer(questionID: String)

    var errorDescription: String? {
        switch self {
        case let .http(status, message, requestID):
            let reason = switch status {
            case 400: "リクエストの内容が受け付けられませんでした"
            case 401, 403: "API キーが無効か、設定されていません"
            case 404, 405: "接続先の URL が正しくありません"
            case 413: "リクエストが大きすぎます"
            case 422: "リクエストの形式が正しくありません"
            case 429: "リクエストが多すぎます（回数の制限）。少し待ってから試してください"
            case 502, 504: "中継サーバーから TypeSafe につながりませんでした"
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
