//
//  JudgmentMechanicsView.swift
//  OdaiAttack
//

import SwiftUI

/// 結果画面から開く「判定のしくみ」。遊んだラウンドの実際の判定を使って、
/// Jev（TypeSafe の AI）への3種類の質問 Noul・Score・Choice が、それぞれ何を答え、ゲームのどこに使われたかを見せる。
struct JudgmentMechanicsView: View {
    let model: GameModel
    @Environment(\.dismiss) private var dismiss

    /// 判定できた言葉（重複と、判定が間に合わなかった・失敗した言葉は除く）。
    private var judged: [JudgedWord] {
        model.entries.compactMap { entry in
            guard case .judged(let judgment) = entry.status else { return nil }
            return JudgedWord(id: entry.id, judgment: judgment, outcome: GameRules.outcome(for: entry))
        }
    }

    /// Jev に判定を頼んだ言葉の数（もう言った言葉は頼まない）。
    private var requestedWordCount: Int {
        model.entries.filter { if case .duplicate = $0.status { false } else { true } }.count
    }

    var body: some View {
        let words = judged
        NavigationStack {
            List {
                OverviewSection(topic: model.topic, judged: words, requestedWordCount: requestedWordCount, bestAnswer: model.bestAnswer)
                NoulSection(topic: model.topic, judged: words)
                ScoreSection(topic: model.topic, judged: words)
                ChoiceSection(topic: model.topic, judged: words, bestAnswer: model.bestAnswer)
            }
            .navigationTitle("判定のしくみ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

private struct JudgedWord: Identifiable {
    let id: UUID
    let judgment: WordJudgment
    let outcome: GameRules.Outcome

    var word: String { judgment.word }

    var isCorrect: Bool {
        if case .correct = outcome { true } else { false }
    }
}

// MARK: - 全体の流れ

private struct OverviewSection: View {
    let topic: String
    let judged: [JudgedWord]
    let requestedWordCount: Int
    let bestAnswer: GameModel.BestAnswerState

    private var averageLatency: Duration? {
        guard !judged.isEmpty else { return nil }
        return judged.map(\.judgment.latency).reduce(.zero, +) / judged.count
    }

    private var requestSummary: String {
        let asksBestAnswer = if case .none = bestAnswer { false } else { true }
        return "言葉の判定 \(requestedWordCount) 回" + (asksBestAnswer ? " + ベスト回答 1 回" : "")
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("TypeSafe の AI「Jev」に3種類の質問をして、正解・点数・ベスト回答を決めています。")
                    .font(.headline)
                FlowStep(symbol: "mic.fill", text: "声は iPhone の音声認識で言葉にする（ここは Jev を使わない）")
                FlowStep(symbol: "paperplane.fill", text: "言葉ごとに ① Noul と ② Score の2つの質問を、1回のリクエストでまとめて Jev に送る")
                FlowStep(symbol: "checkmark.circle.fill", text: "返ってきた確率から、アプリが正解・不正解（①）と点数（②）を決める")
                FlowStep(symbol: "trophy.fill", text: "ラウンドのあと、正解した言葉を選択肢にして ③ Choice でベスト回答を選ぶ")
            }
            .padding(.vertical, 4)

            Text("Jev は文章を書かず、決まった形の答え（確率の数値）だけを返します。そのため答えをそのままプログラムで使えます。正解のしきい値や点数のルールは、アプリの側で決めています。")
                .font(.callout)
                .foregroundStyle(.secondary)

            LabeledContent("モデル", value: WordJudge.model)
            LabeledContent("Jev へのリクエスト", value: requestSummary)
            if let averageLatency {
                LabeledContent("言葉の判定にかかった時間（平均）", value: averageLatency.millisecondsText)
            }
        } header: {
            Text("お題「\(topic)」のラウンド")
        }
    }
}

private struct FlowStep: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
        }
        .font(.subheadline)
    }
}

// MARK: - ① Noul

private struct NoulSection: View {
    let topic: String
    let judged: [JudgedWord]

    var body: some View {
        Section {
            Text("「〜ですか？」という質問に、yes の確率（0〜1）で答えます。ここでは「言葉がお題に当てはまるか」を聞き、\(GameRules.correctThreshold.formatted()) 以上（縦線より右）なら正解にしています。")
                .font(.callout)

            if judged.isEmpty {
                Text("判定できた言葉がありません")
                    .foregroundStyle(.secondary)
            }
            ForEach(judged) { word in
                HStack(spacing: 10) {
                    WordLabel(word.word)
                    ProbabilityBar(
                        value: word.judgment.fitProbability,
                        threshold: GameRules.correctThreshold,
                        tint: word.isCorrect ? .green : .red
                    )
                    Text(word.judgment.fitProbability.twoDecimals)
                        .font(.callout)
                        .monospacedDigit()
                    Image(systemName: word.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(word.isCorrect ? .green : .red)
                        .accessibilityLabel(word.isCorrect ? "正解" : "不正解")
                }
            }

            SentQuestion(
                instructions: WordJudge.fitsTopicInstructions,
                answersTitle: "答えの基準（criteria）",
                answers: [
                    "yes（true）: \(WordJudge.fitsTopicCriteria.yes)",
                    "no（false）: \(WordJudge.fitsTopicCriteria.no)",
                ],
                stateTitle: "データ（state）の例。言葉ごとに送る",
                state: stateJSON(["topic": topic, "word": judged.first?.word ?? "…"])
            )
        } header: {
            SectionTitle(number: "①", name: "Noul", question: "お題に当てはまる？")
        }
    }
}

// MARK: - ② Score

private struct ScoreSection: View {
    let topic: String
    let judged: [JudgedWord]

    private var correct: [JudgedWord] { judged.filter(\.isCorrect) }

    /// 点数の決め方。`GameRules.surpriseBonuses` と同じく上から順に見る。
    private var pointsRule: String {
        let bonuses = GameRules.surpriseBonuses.map {
            "\($0.maxTypicality.formatted()) 以下なら +\(GameRules.pointsForCorrect + $0.bonus)"
        }
        return (bonuses + ["それより上（定番寄り）なら +\(GameRules.pointsForCorrect)"]).joined(separator: "、")
    }

    var body: some View {
        Section {
            Text("用意した段階のどれに当たるかを、段階ごとの確率で答えます。ここでは「どれくらい定番の答えか」を\(WordJudge.typicalityLevels.count)段階で聞いています。段階の番号（0〜\(WordJudge.maxTypicality)）を確率で重み付けした平均が Score で、低いほど意外な答えです。")
                .font(.callout)
            if let example = correct.first {
                Text("例: \(example.word) = \(weightedSum(example.judgment.typicalityProbabilities)) ≈ \(example.judgment.typicality.twoDecimals)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("正解した言葉の点数は Score で決めています: \(pointsRule)。")
                .font(.callout)

            LevelLegend()

            if correct.isEmpty {
                Text("正解した言葉がありません")
                    .foregroundStyle(.secondary)
            }
            ForEach(correct) { word in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(word.word)
                            .font(.headline)
                        Spacer()
                        Text("Score \(word.judgment.typicality.twoDecimals)")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text("+\(word.outcome.points)")
                            .font(.headline)
                            .monospacedDigit()
                    }
                    LevelBar(probabilities: word.judgment.typicalityProbabilities)
                    Text(topLevels(word.judgment.typicalityProbabilities))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            if correct.count < judged.count {
                Text("不正解の言葉は点にならないので、ここでは省いています。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SentQuestion(
                instructions: WordJudge.typicalityInstructions,
                answersTitle: "段階（levels）",
                answers: WordJudge.typicalityLevels.enumerated().map { level, item in
                    "\(level)（\(item.label)）: \(item.criterion)"
                },
                stateTitle: "データ（state）: ① と同じリクエストで送る",
                state: stateJSON(["topic": topic, "word": judged.first?.word ?? "…"])
            )
        } header: {
            SectionTitle(number: "②", name: "Score", question: "どれくらい定番？")
        }
    }

    /// 「0×0.01 + 1×0.02 + …」の形。
    private func weightedSum(_ probabilities: [Double]) -> String {
        probabilities.enumerated()
            .map { level, probability in "\(level)×\(probability.twoDecimals)" }
            .joined(separator: " + ")
    }

    /// 確率の高い2つの段階（例: "定番 90%・ふつう 7%"）。
    private func topLevels(_ probabilities: [Double]) -> String {
        zip(WordJudge.typicalityLevels, probabilities)
            .sorted { $0.1 > $1.1 }
            .prefix(2)
            .map { "\($0.0.label) \($0.1.formatted(.percent.precision(.fractionLength(0))))" }
            .joined(separator: "・")
    }
}

/// 典型度の段階の色。
private enum LevelStyle {
    static func color(_ level: Int) -> Color {
        switch level {
        case 0: .gray
        case 1: .orange
        case 2: .teal
        default: .blue
        }
    }
}

private struct LevelLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(WordJudge.typicalityLevels.enumerated()), id: \.offset) { level, item in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LevelStyle.color(level))
                        .frame(width: 12, height: 12)
                    Text(item.label)
                }
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

/// 段階ごとの確率を1本の帯に並べる。
private struct LevelBar: View {
    let probabilities: [Double]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(probabilities.enumerated()), id: \.offset) { level, probability in
                    Rectangle()
                        .fill(LevelStyle.color(level))
                        .frame(width: geometry.size.width * min(max(probability, 0), 1))
                }
            }
        }
        .frame(height: 14)
        .background(.quaternary)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

// MARK: - ③ Choice

private struct ChoiceSection: View {
    let topic: String
    let judged: [JudgedWord]
    let bestAnswer: GameModel.BestAnswerState

    var body: some View {
        Section {
            Text("用意した選択肢から1つを選び、選択肢ごとの確率も返します。1語ずつ判定する Noul や Score と違って、言葉どうしを見比べられます。ここでは正解した言葉を選択肢にして、お題によく合っていて思いつく人が少ない言葉を1つ選んでいます。")
                .font(.callout)

            switch bestAnswer {
            case .chosen(let best):
                ForEach(Array(best.candidates.enumerated()), id: \.offset) { rank, candidate in
                    HStack(spacing: 10) {
                        WordLabel(candidate.word)
                        ProbabilityBar(value: candidate.probability, tint: rank == 0 ? .orange : .secondary)
                        Text(candidate.probability.formatted(.percent.precision(.fractionLength(0))))
                            .font(.callout)
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                        Image(systemName: "trophy.fill")
                            .foregroundStyle(.orange)
                            .opacity(rank == 0 ? 1 : 0)
                            .accessibilityLabel("ベスト回答")
                            .accessibilityHidden(rank != 0)
                    }
                }
                LabeledContent("確信度", value: best.confidence.twoDecimals)
                Text("確率が1つの言葉に集中しているほど 1 に近くなります。\(GameRules.bestAnswerClearConfidence.formatted()) より低いときは僅差として、結果画面に2位も出しています。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("かかった時間", value: best.latency.millisecondsText)
            case .choosing:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("ベスト回答を選んでいます…")
                        .foregroundStyle(.secondary)
                }
            case .none:
                Text("正解した言葉が \(GameRules.bestAnswerMinimumCandidates) 語以上あると、ここで選びます。")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text("ベスト回答を選べませんでした: \(message)")
                    .foregroundStyle(.secondary)
            }

            SentQuestion(
                instructions: WordJudge.bestAnswerInstructions,
                answersTitle: "選択肢（options）: 正解した言葉",
                answers: [options.joined(separator: "、")],
                stateTitle: "データ（state）",
                state: stateJSON(["topic": topic])
            )
        } header: {
            SectionTitle(number: "③", name: "Choice", question: "ベスト回答はどれ？")
        }
    }

    private var options: [String] {
        let words = judged.filter(\.isCorrect).map(\.word)
        return words.isEmpty ? ["…"] : words
    }
}

// MARK: - 共通の部品

private struct SectionTitle: View {
    let number: String
    let name: String
    let question: String

    var body: some View {
        HStack(spacing: 6) {
            Text(number)
            Text(name)
                .bold()
            Text("— \(question)")
        }
        .font(.subheadline)
        .textCase(nil)
    }
}

/// 棒グラフの左に出す言葉。長い言葉は縮めて1行に収める。
private struct WordLabel: View {
    let word: String

    init(_ word: String) {
        self.word = word
    }

    var body: some View {
        Text(word)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: 96, alignment: .leading)
    }
}

/// 0〜1 の値を横棒で出す。`threshold` があれば、その位置に縦線を引く。
private struct ProbabilityBar: View {
    let value: Double
    var threshold: Double?
    var tint: Color

    init(value: Double, threshold: Double? = nil, tint: Color) {
        self.value = value
        self.threshold = threshold
        self.tint = tint
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * min(max(value, 0), 1))
                if let threshold {
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2)
                        .offset(x: geometry.size.width * threshold - 1)
                }
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

/// Jev に送った質問（英語のまま）と、一緒に送ったデータ（state）。
private struct SentQuestion: View {
    let instructions: String
    let answersTitle: String
    let answers: [String]
    let stateTitle: String
    let state: String

    var body: some View {
        DisclosureGroup("Jev に送った内容") {
            VStack(alignment: .leading, spacing: 10) {
                SentPart(title: "質問（instructions）", lines: [instructions])
                SentPart(title: answersTitle, lines: answers)
                SentPart(title: stateTitle, lines: [state])
                Text("質問文は毎回同じで、お題や言葉はデータとして別に送ります。質問文の `topic` や `word` は、データの項目を指しています。質問文を英語にしているのは、Jev の主な学習言語が英語だからです。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .font(.subheadline)
    }
}

private struct SentPart: View {
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(lines, id: \.self) { line in
                // 付けないと、開いたときに長い行が途中で「…」になることがあった（リストの行の高さが足りない）
                Text(line)
                    .font(.caption.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

/// state を、実際に送るときと同じ形の JSON にする（キーの順も `SystemOneHTTP` と同じ）。
private func stateJSON(_ state: [String: String]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let data = try? encoder.encode(state) else { return "" }
    return String(decoding: data, as: UTF8.self)
}
