//
//  APIKeyMissingBanner.swift
//  OdaiAttack
//

import SwiftUI

/// API キーが設定されていないときに画面の上に出す案内。
struct APIKeyMissingBanner: View {
    var body: some View {
        Label("API キーが設定されていません。Config/Secrets.xcconfig の TYPESAFE_API_KEY にキーを書いて、ビルドし直してください。", systemImage: "key.slash")
            .foregroundStyle(.orange)
    }
}
