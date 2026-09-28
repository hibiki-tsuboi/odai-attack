//
//  GameView.swift
//  OdaiAttack
//

import SwiftUI

/// ゲームの画面。タイトル → カウントダウン → プレイ → 結果を切り替える。
struct GameView: View {
    @State private var model = GameModel()
    @State private var showsLabs = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .title, .preparing:
                TitleScreen(model: model, showsLabs: $showsLabs)
            case .countdown(let count):
                CountdownScreen(topic: model.topic, count: count)
            case .playing, .finishing:
                PlayingScreen(model: model)
            case .result:
                ResultScreen(model: model)
            }
        }
        .sheet(isPresented: $showsLabs) {
            LabsView()
        }
        .onChange(of: scenePhase) { _, phase in
            // バックグラウンドではマイクが止まるので、遊んでいる途中ならやめる
            if phase == .background {
                model.quit()
            }
        }
    }
}

private struct TitleScreen: View {
    let model: GameModel
    @Binding var showsLabs: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("お題アタック")
                .font(.system(size: 48, weight: .black, design: .rounded))
            Text("お題に合う言葉を\n\(Int(GameRules.roundDuration.inSeconds))秒でできるだけたくさん言おう")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()

            if model.isAPIKeyMissing {
                APIKeyMissingBanner()
                    .padding(.horizontal)
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if case .preparing(let message) = model.phase {
                ProgressView(message)
                    .frame(height: 60)
            } else {
                Button {
                    model.start()
                } label: {
                    Text("スタート")
                        .font(.title.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canStart)
                .padding(.horizontal, 32)
            }

            Button("検証画面を開く") {
                showsLabs = true
            }
            .font(.footnote)
            .disabled(model.phase != .title)
            .padding(.bottom)
        }
    }
}

#Preview {
    GameView()
}
