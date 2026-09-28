//
//  ResultScreen.swift
//  OdaiAttack
//

import SwiftUI

/// 結果の画面。得点と、言った言葉それぞれの正解・不正解と確率を出す。
struct ResultScreen: View {
    let model: GameModel

    private var correctCount: Int {
        model.entries.filter { if case .correct = GameRules.outcome(for: $0) { true } else { false } }.count
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Text("お題「\(model.topic)」")
                        .font(.headline)
                    Text("\(model.score) 点")
                        .font(.system(size: 64, weight: .black, design: .rounded))
                        .monospacedDigit()
                    Text("正解 \(correctCount) 語 / 聞き取れた言葉 \(model.entries.count) 語")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            }

            Section("言った言葉") {
                if model.entries.isEmpty {
                    Text("聞き取れた言葉はありませんでした")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.entries) { entry in
                    ResultRow(entry: entry)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 16) {
                Button("タイトルへ") {
                    model.quit()
                }
                .buttonStyle(.bordered)
                Button("次のお題へ") {
                    model.start()
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }
}

private struct ResultRow: View {
    let entry: SpokenEntry

    var body: some View {
        let outcome = GameRules.outcome(for: entry)
        HStack(spacing: 12) {
            Image(systemName: outcome.symbolName)
                .font(.title2)
                .foregroundStyle(outcome.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.word)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(outcome.points > 0 ? "+\(outcome.points)" : "0")
                .font(.title3.bold())
                .monospacedDigit()
                .foregroundStyle(outcome.points > 0 ? .primary : .secondary)
        }
    }

    private var detail: String {
        switch entry.status {
        case .judged(let judgment):
            "当てはまる確率 \(judgment.fitProbability.formatted(.percent.precision(.fractionLength(0)))) · 典型度 \(judgment.typicalityLabel)（\(judgment.typicality.twoDecimals)）"
        case .duplicate:
            "もう言った言葉"
        case .judging:
            "判定が間に合いませんでした"
        case .failed(let message):
            message
        }
    }
}

private extension GameRules.Outcome {
    var symbolName: String {
        switch self {
        case .correct: "checkmark.circle.fill"
        case .wrong: "xmark.circle.fill"
        case .duplicate: "arrow.uturn.backward.circle"
        case .unjudged: "questionmark.circle"
        }
    }
}
