//
//  ResultScreen.swift
//  OdaiAttack
//

import SwiftUI

/// 結果の画面。得点と、言った言葉それぞれの正解・不正解と確率を出す。
struct ResultScreen: View {
    let model: GameModel

    /// ベスト回答に選ばれた、正解の行か（同じ言葉の「重複」の行には付けない）。
    private func isBest(_ entry: SpokenEntry) -> Bool {
        guard case .chosen(let best) = model.bestAnswer, case .correct = GameRules.outcome(for: entry) else { return false }
        return entry.word == best.word
    }

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

            switch model.bestAnswer {
            case .none:
                EmptyView()
            case .choosing:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("ベスト回答を選んでいます…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            case .chosen(let best):
                Section {
                    BestAnswerCard(best: best)
                }
            case .failed(let message):
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ベスト回答を選べませんでした")
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("言った言葉") {
                if model.entries.isEmpty {
                    Text("聞き取れた言葉はありませんでした")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.entries) { entry in
                    ResultRow(entry: entry, isBest: isBest(entry))
                }
            }
        }
        .animation(.spring(duration: 0.4), value: model.bestAnswer)
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

/// 今回のベスト回答。僅差のときは2位も出す。
private struct BestAnswerCard: View {
    let best: BestAnswer

    var body: some View {
        VStack(spacing: 6) {
            Label("今回のベスト回答", systemImage: "trophy.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(best.word)
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
            if best.confidence < GameRules.bestAnswerClearConfidence, let runnerUp = best.runnerUp {
                Text("僅差で2位: \(runnerUp)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("正解した言葉の中から、お題によく合っていて思いつく人が少ないものを Jev が選びました")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct ResultRow: View {
    let entry: SpokenEntry
    let isBest: Bool

    var body: some View {
        let outcome = GameRules.outcome(for: entry)
        HStack(spacing: 12) {
            Image(systemName: outcome.symbolName)
                .font(.title2)
                .foregroundStyle(outcome.color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.word)
                        .font(.headline)
                    if isBest {
                        Image(systemName: "trophy.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("ベスト回答")
                    }
                }
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
