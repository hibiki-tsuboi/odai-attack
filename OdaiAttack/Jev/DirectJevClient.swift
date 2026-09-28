//
//  DirectJevClient.swift
//  OdaiAttack
//

import Foundation

/// TypeSafe API を直接呼ぶ `JevClient`（開発用）。
/// API キーがアプリの Info.plist に平文で入るので、Debug ビルドでしか使えないようにしている（Release ではキーを入れない）。
nonisolated struct DirectJevClient: JevClient {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    let connectionName = "TypeSafe に直接"
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

    func systemOne<State: Encodable & Sendable>(_ request: SystemOneRequest<State>, retry: JevRetryPolicy) async throws -> SystemOneResponse {
        try await SystemOneHTTP.post(request, to: Self.endpoint, headers: ["Authorization": "Bearer \(apiKey)"], session: session, retry: retry)
    }
}
