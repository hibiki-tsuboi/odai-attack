//
//  JudgeLabView.swift
//  OdaiAttack
//

import SwiftUI

/// フェーズ1の検証画面。テキストで入力した言葉を Jev で判定し、結果と通信時間を表示する。
struct JudgeLabView: View {
    @State private var model = JudgeLabModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if model.isAPIKeyMissing {
                    Section {
                        APIKeyMissingBanner()
                    }
                }

                Section("お題") {
                    TextField("例: 赤いもの", text: $model.topic)
                }

                Section("言葉") {
                    TextField("例: りんご", text: $model.word)
                        .submitLabel(.go)
                        .onSubmit(judgeOnce)
                    Button(action: judgeOnce) {
                        HStack {
                            Text("判定")
                            if model.isRunning && model.benchmarkRun == nil {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!model.canRun)
                    Button("\(JudgeLabModel.benchmarkRuns)回連続で判定", action: runBenchmark)
                        .disabled(!model.canRun)
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                if let latest = model.latest {
                    Section("結果") {
                        JudgmentDetail(judgment: latest)
                    }
                }

                if let run = model.benchmarkRun {
                    Section("レイテンシ") {
                        ProgressView(value: Double(run - 1), total: Double(JudgeLabModel.benchmarkRuns)) {
                            Text("連続判定中 \(run) / \(JudgeLabModel.benchmarkRuns)")
                        }
                    }
                } else if let benchmark = model.benchmark {
                    Section("レイテンシ（\(benchmark.latencies.count)回）") {
                        BenchmarkSummary(benchmark: benchmark)
                    }
                }

                if !model.history.isEmpty {
                    Section("履歴") {
                        HistoryHeader()
                        ForEach(model.history) { judgment in
                            HistoryRow(judgment: judgment)
                        }
                    }
                }
            }
            .navigationTitle("判定テスト")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func judgeOnce() {
        Task { await model.judgeOnce() }
    }

    private func runBenchmark() {
        Task { await model.runBenchmark() }
    }
}

private struct JudgmentDetail: View {
    let judgment: WordJudgment

    var body: some View {
        LabeledContent("言葉", value: "\(judgment.word)（\(judgment.topic)）")
        LabeledContent("当てはまる確率（Noul）", value: judgment.fitProbability.twoDecimals)
        LabeledContent("典型度（Score）", value: "\(judgment.typicality.twoDecimals) / \(WordJudge.maxTypicality)（\(judgment.typicalityLabel)）")
        LabeledContent("通信時間", value: judgment.latency.millisecondsText)
        Text("\(judgment.model) · 入力 \(judgment.inputTokens) トークン · Score の確信度 \(judgment.typicalityConfidence.twoDecimals)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct BenchmarkSummary: View {
    let benchmark: LatencyBenchmark

    var body: some View {
        LabeledContent("最小", value: benchmark.min.millisecondsText)
        LabeledContent("平均", value: benchmark.average.millisecondsText)
        LabeledContent("最大", value: benchmark.max.millisecondsText)
        Text("\(benchmark.word)（\(benchmark.topic)）実行順: \(benchmark.latencies.map { $0.roundedMilliseconds }.joined(separator: ", ")) ms")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct HistoryHeader: View {
    @ScaledMetric private var columnWidth = 52.0

    var body: some View {
        HStack {
            Text("言葉")
            Spacer()
            Text("Noul").frame(width: columnWidth, alignment: .trailing)
            Text("Score").frame(width: columnWidth, alignment: .trailing)
            Text("ms").frame(width: columnWidth, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct HistoryRow: View {
    let judgment: WordJudgment
    @ScaledMetric private var columnWidth = 52.0

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(judgment.word)
                Text(judgment.topic)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(judgment.fitProbability.twoDecimals).frame(width: columnWidth, alignment: .trailing)
            Text(judgment.typicality.twoDecimals).frame(width: columnWidth, alignment: .trailing)
            Text(judgment.latency.roundedMilliseconds).frame(width: columnWidth, alignment: .trailing)
        }
        .monospacedDigit()
    }
}

#Preview {
    JudgeLabView()
}
