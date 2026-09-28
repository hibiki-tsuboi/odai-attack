//
//  LabsView.swift
//  OdaiAttack
//

import SwiftUI

/// 判定や声の区切りを調整するための検証画面（フェーズ1・2）。タイトル画面から開く。
struct LabsView: View {
    var body: some View {
        TabView {
            Tab("音声判定", systemImage: "mic") {
                VoiceLabView()
            }
            Tab("テキスト判定", systemImage: "keyboard") {
                JudgeLabView()
            }
        }
    }
}

#Preview {
    LabsView()
}
