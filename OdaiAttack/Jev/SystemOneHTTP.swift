//
//  SystemOneHTTP.swift
//  OdaiAttack
//

import Foundation
import os

/// System One API の JSON を POST して、回答を読む。TypeSafe を直接呼ぶときも、中継サーバーを通すときも同じ形で送る。
/// 混雑やタイムアウトで失敗したときは、`JevRetryPolicy` に従って少し待ってから送り直す。
nonisolated enum SystemOneHTTP {
    /// 再試行するサーバーの応答（公式 SDK と同じ）。429 は回数の制限、529 は TypeSafe の混雑。
    private static let retryableStatuses: Set<Int> = Set([408, 429]).union(500...599)
    /// 再試行する通信のエラー。
    private static let retryableURLErrors: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]

    private static let logger = Logger(subsystem: "jp.hibiki.OdaiAttack", category: "Jev")

    static func post<State: Encodable & Sendable>(
        _ request: SystemOneRequest<State>,
        to url: URL,
        headers: [String: String],
        session: URLSession,
        retry policy: JevRetryPolicy
    ) async throws -> SystemOneResponse {
        var urlRequest = URLRequest(url: url, timeoutInterval: policy.attemptTimeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        // Dictionary の並び順は起動のたびに変わる。state の並びが変わると答えが変わりうるので、
        // キーを並べ替えて同じ入力なら毎回同じ JSON を送る。
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        urlRequest.httpBody = try encoder.encode(request)

        var attempt = 0
        while true {
            attempt += 1
            let canRetry = attempt < policy.maxAttempts

            let data: Data
            let http: HTTPURLResponse
            do {
                let (body, response) = try await session.data(for: urlRequest)
                guard let response = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                (data, http) = (body, response)
            } catch let error as URLError where canRetry && retryableURLErrors.contains(error.code) {
                try await waitBeforeRetry(policy.backoff(afterAttempt: attempt), attempt: attempt, reason: error.localizedDescription)
                continue
            }

            if (200..<300).contains(http.statusCode) {
                return try JSONDecoder().decode(SystemOneResponse.self, from: data)
            }
            if canRetry, retryableStatuses.contains(http.statusCode) {
                let delay = retryAfter(in: http).map { min($0, policy.maxBackoff) } ?? policy.backoff(afterAttempt: attempt)
                try await waitBeforeRetry(delay, attempt: attempt, reason: "HTTP \(http.statusCode)")
                continue
            }
            throw JevError.http(
                status: http.statusCode,
                message: errorMessage(from: data),
                requestID: http.value(forHTTPHeaderField: "x-typesafe-request-id")
            )
        }
    }

    /// 待つ。待っている間に呼び出し元が取り消されたら、送り直さずに CancellationError を投げる。
    private static func waitBeforeRetry(_ seconds: TimeInterval, attempt: Int, reason: String) async throws {
        logger.info("Jev 再試行: \(attempt) 回目が失敗（\(reason, privacy: .public)）、\(seconds * 1000, format: .fixed(precision: 0)) ms 待って送り直す")
        try await Task.sleep(for: .seconds(seconds))
    }

    /// サーバーが指定した待ち時間（`retry-after-ms` か、秒の `Retry-After`）。
    private static func retryAfter(in response: HTTPURLResponse) -> TimeInterval? {
        if let milliseconds = response.value(forHTTPHeaderField: "retry-after-ms").flatMap(Double.init) {
            return milliseconds / 1000
        }
        return response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
    }

    /// エラー本文からメッセージを取り出す。TypeSafe も中継サーバーも
    /// `{"detail": {"error_type": "...", "message": "..."}}` の形で返す（2026-09-28 に確認）。
    private static func errorMessage(from data: Data) -> String? {
        if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = body["detail"] as? [String: Any], let message = detail["message"] as? String {
                return message
            }
            if let detail = body["detail"] as? String {
                return detail
            }
            if let message = body["message"] as? String {
                return message
            }
        }
        let raw = String(decoding: data.prefix(200), as: UTF8.self)
        return raw.isEmpty ? nil : raw
    }
}

/// Jev を呼ぶときの、タイムアウトと再試行のしかた。使い分けは `WordJudge` で決める。
nonisolated struct JevRetryPolicy: Sendable {
    /// 最初の1回を含めて、何回まで送るか。
    var maxAttempts: Int
    /// 1回あたりのタイムアウト（秒）。
    var attemptTimeout: TimeInterval
    /// 1回目の再試行の前に待つ時間（秒）。そのあとは倍々にする。
    var initialBackoff: TimeInterval
    /// 待つ時間の上限（秒）。サーバーが指定した待ち時間もここで頭打ちにする。
    var maxBackoff: TimeInterval

    /// `attempt` 回目が失敗したあとに待つ時間。一斉に送り直さないよう、最大25%短くばらつかせる（公式 SDK と同じ）。
    func backoff(afterAttempt attempt: Int) -> TimeInterval {
        let base = min(initialBackoff * pow(2, Double(attempt - 1)), maxBackoff)
        return base * (1 - Double.random(in: 0..<0.25))
    }
}
