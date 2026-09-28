//
//  VoiceLabView.swift
//  OdaiAttack
//

import SwiftUI

/// フェーズ2の検証画面。声で言った言葉を区切って Jev で判定し、言った順に結果を表示する。
struct VoiceLabView: View {
    @State private var model = VoiceLabModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if model.isAPIKeyMissing {
                        Section {
                            APIKeyMissingBanner()
                        }
                    }

                    Section("お題") {
                        TextField("例: 赤いもの", text: $model.topic)
                            .disabled(model.state != .idle)
                    }

                    if let errorMessage = model.errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }
                    }

                    Section("確定した言葉（言った順）") {
                        if model.entries.isEmpty {
                            Text("まだありません")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.entries) { entry in
                            SpokenEntryRow(entry: entry)
                        }
                    }
                }
                .onChange(of: model.entries.count) {
                    guard let last = model.entries.last else { return }
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                ListeningPanel(model: model)
            }
            .navigationTitle("音声判定")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("クリア", action: model.clear)
                        .disabled(model.entries.isEmpty)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // バックグラウンドではマイクが止まるので、聞くのをやめる
            if phase == .background {
                Task { await model.stopListening() }
            }
        }
        .onDisappear {
            Task { await model.stopListening() }
        }
    }
}

/// 画面下に固定する、認識中の文字列・音量・マイクボタン。
private struct ListeningPanel: View {
    let model: VoiceLabModel

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 4) {
                Text("認識中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.partialText.isEmpty ? "―" : model.partialText)
                    .font(.title2.bold())
                    .foregroundStyle(model.partialText.isEmpty ? .tertiary : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }

            LevelMeter(level: model.level, threshold: model.threshold, isSpeaking: model.isSpeaking)

            Button {
                Task { await model.toggleListening() }
            } label: {
                Image(systemName: model.state == .listening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(model.state == .listening ? AnyShapeStyle(.red) : AnyShapeStyle(.tint), in: Circle())
                    .opacity(model.canToggleListening ? 1 : 0.4)
            }
            .disabled(!model.canToggleListening)
            .accessibilityLabel(model.state == .listening ? "止める" : "聞き始める")

            Text(model.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(.bar)
    }
}

/// 入力の音量。縦線は声とみなすしきい値で、声と判定している間は緑になる。
private struct LevelMeter: View {
    let level: Float
    let threshold: Float
    let isSpeaking: Bool

    /// 表示する音量の範囲（dBFS）。
    private static let range: ClosedRange<Float> = -70...0

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(isSpeaking ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .frame(width: width * Self.position(of: level))
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2)
                        .offset(x: width * Self.position(of: threshold) - 1)
                }
            }
            .frame(height: 8)
            .animation(.linear(duration: 0.1), value: level)

            HStack {
                Text("音量（縦線より大きいと声とみなす）")
                Spacer()
                Text(isSpeaking ? "話しています" : "静か")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }

    private static func position(of decibels: Float) -> CGFloat {
        let clamped = min(max(decibels, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}

private struct SpokenEntryRow: View {
    let entry: SpokenEntry

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.word)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if entry.revealedAt == nil {
            ProgressView()
        } else {
            switch entry.status {
            case .duplicate:
                Text("重複")
                    .foregroundStyle(.secondary)
            case .judging:
                ProgressView()
            case .judged(let judgment):
                VStack(spacing: 0) {
                    Text(judgment.fitProbability.twoDecimals)
                        .font(.title3.bold())
                        .monospacedDigit()
                    Text("Noul")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var detail: String {
        guard entry.revealedAt != nil else { return "判定中…" }
        switch entry.status {
        case .duplicate:
            return "もう言った言葉なので判定しません"
        case .judging:
            return "判定中…"
        case .judged(let judgment):
            var parts = [
                "Score \(judgment.typicality.twoDecimals) / \(WordJudge.maxTypicality)（\(judgment.typicalityLabel)）",
                "判定 \(judgment.latency.millisecondsText)",
            ]
            if let speechToReveal = entry.speechToReveal {
                parts.append("話し終わりから \(speechToReveal.millisecondsText)")
            }
            return parts.joined(separator: " · ")
        case .failed(let message):
            return message
        }
    }
}

#Preview {
    VoiceLabView()
}
