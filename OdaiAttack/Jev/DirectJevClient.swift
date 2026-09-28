//
//  DirectJevClient.swift
//  OdaiAttack
//

import Foundation

/// TypeSafe API を直接呼ぶ `JevClient`（開発用）。
/// API キーがアプリの Info.plist に平文で入るので、TestFlight などで他人に配る前に中継サーバー版へ差し替える。
nonisolated struct DirectJevClient: JevClient {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    /// 1回の通信のタイムアウト（公式 SDK の既定値と同じ）。
    static let timeout: TimeInterval = 10

    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Info.plist の `TypeSafeAPIKey`（Config/Secrets.xcconfig の `TYPESAFE_API_KEY` がビルド時に入る）からクライアントを作る。
    /// キーが空なら nil。
    static func fromInfoPlist(_ bundle: Bundle = .main) -> DirectJevClient? {
        let key = (bundle.object(forInfoDictionaryKey: "TypeSafeAPIKey") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return DirectJevClient(apiKey: key)
    }

    func systemOne<State: Encodable & Sendable>(_ request: SystemOneRequest<State>) async throws -> SystemOneResponse {
        var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: Self.timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
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
                message: Self.errorMessage(from: data),
                requestID: http.value(forHTTPHeaderField: "x-typesafe-request-id")
            )
        }
        return try JSONDecoder().decode(SystemOneResponse.self, from: data)
    }

    /// エラー本文からメッセージを取り出す。
    /// 実際の本文は `{"detail": {"error_type": "...", "message": "..."}}`（2026-09-28 に確認）。
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
