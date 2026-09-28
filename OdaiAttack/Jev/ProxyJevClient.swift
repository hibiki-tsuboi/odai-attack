//
//  ProxyJevClient.swift
//  OdaiAttack
//

import Foundation

/// 自前の中継サーバー（proxy/ の Cloudflare Worker）を通して Jev を呼ぶ `JevClient`。
/// API キーは中継サーバーにだけあり、アプリには入らない。
nonisolated struct ProxyJevClient: JevClient {
    /// 中継サーバーが回数の制限に使う、インストールごとの ID を送るヘッダー。
    static let installIDHeader = "X-OdaiAttack-Install-ID"

    let connectionName = "中継サーバー経由"
    let endpoint: URL
    private let installID: String
    private let session: URLSession

    init(endpoint: URL, installID: String = InstallID.current, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.installID = installID
        self.session = session
    }

    /// Info.plist の `JevProxyHost`（Config/App.xcconfig の `JEV_PROXY_HOST` がビルド時に入る）からクライアントを作る。
    /// ホスト名が空なら nil。
    static func fromInfoPlist(_ bundle: Bundle = .main) -> ProxyJevClient? {
        let host = (bundle.object(forInfoDictionaryKey: "JevProxyHost") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let endpoint = URL(string: "https://\(host)/v1/systemone") else { return nil }
        return ProxyJevClient(endpoint: endpoint)
    }

    func systemOne<State: Encodable & Sendable>(_ request: SystemOneRequest<State>) async throws -> SystemOneResponse {
        try await SystemOneHTTP.post(request, to: endpoint, headers: [Self.installIDHeader: installID], session: session)
    }
}

/// アプリをインストールするごとに作るランダムな ID。中継サーバーが回数の制限に使う（端末や人は特定できない）。
nonisolated enum InstallID {
    private static let key = "InstallID"

    static var current: String {
        if let id = UserDefaults.standard.string(forKey: key) {
            return id
        }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}
