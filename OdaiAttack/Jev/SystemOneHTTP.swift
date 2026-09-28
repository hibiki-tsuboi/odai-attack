//
//  SystemOneHTTP.swift
//  OdaiAttack
//

import Foundation

/// System One API の JSON を POST して、回答を読む。TypeSafe を直接呼ぶときも、中継サーバーを通すときも同じ形で送る。
nonisolated enum SystemOneHTTP {
    /// 1回の通信のタイムアウト（公式 SDK の既定値と同じ）。
    static let timeout: TimeInterval = 10

    static func post<State: Encodable & Sendable>(
        _ request: SystemOneRequest<State>,
        to url: URL,
        headers: [String: String],
        session: URLSession
    ) async throws -> SystemOneResponse {
        var urlRequest = URLRequest(url: url, timeoutInterval: timeout)
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

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JevError.http(
                status: http.statusCode,
                message: errorMessage(from: data),
                requestID: http.value(forHTTPHeaderField: "x-typesafe-request-id")
            )
        }
        return try JSONDecoder().decode(SystemOneResponse.self, from: data)
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
