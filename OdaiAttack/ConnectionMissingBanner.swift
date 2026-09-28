//
//  ConnectionMissingBanner.swift
//  OdaiAttack
//

import SwiftUI

/// Jev への接続先（中継サーバーか API キー）が設定されていないときに出す案内。
struct ConnectionMissingBanner: View {
    var body: some View {
        Label("Jev への接続先が設定されていません。Config/App.xcconfig の JEV_PROXY_HOST（中継サーバー）か、Debug ビルドなら Config/Secrets.xcconfig の TYPESAFE_API_KEY を設定して、ビルドし直してください。", systemImage: "network.slash")
            .foregroundStyle(.orange)
    }
}
