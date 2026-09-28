//
//  PlayingScreen.swift
//  OdaiAttack
//

import SwiftUI

/// お題を見せてカウントダウンする画面。
struct CountdownScreen: View {
    let topic: String
    let count: Int

    var body: some View {
        VStack(spacing: 16) {
            Text("お題")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(topic)
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
            Text("\(count)")
                .font(.system(size: 180, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tint)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: count)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 声で言っている間の画面。残り時間を大きく出し、正解のたびに画面を光らせる。
struct PlayingScreen: View {
    let model: GameModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Text("お題")
                    .foregroundStyle(.secondary)
                Text(model.topic)
                    .bold()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .font(.title2)

            TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                RemainingTime(seconds: model.remainingSeconds, total: GameRules.roundDuration.inSeconds)
            }

            Text("\(model.score) 点")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: model.score)

            LatestWord(entry: model.latestEntry)
                .frame(height: 100)

            Text(model.partialText.isEmpty ? " " : model.partialText)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if model.phase == .finishing {
                Text("時間切れ！")
                    .font(.title.bold())
                    .frame(height: 44)
            } else {
                Button("やめる", role: .cancel) {
                    model.quit()
                }
                .frame(height: 44)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .keyframeAnimator(initialValue: 0.0, trigger: model.correctRevealCount) { content, glow in
            content.background {
                Color.yellow.opacity(glow).ignoresSafeArea()
            }
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(0.6, duration: 0.05)
                LinearKeyframe(0.0, duration: 0.35)
            }
        }
    }
}

/// 残り時間。残り3秒からは赤くする。
private struct RemainingTime: View {
    let seconds: Double
    let total: Double

    private var color: Color { seconds <= 3 ? .red : .accentColor }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 14)
            Circle()
                .trim(from: 0, to: seconds / total)
                .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(seconds, format: .number.precision(.fractionLength(1)))
                .font(.system(size: 96, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(seconds <= 3 ? .red : .primary)
        }
        .frame(width: 240, height: 240)
    }
}

/// 最後に結果が出た言葉と点数。
private struct LatestWord: View {
    let entry: SpokenEntry?

    var body: some View {
        ZStack {
            if let entry {
                let outcome = GameRules.outcome(for: entry)
                VStack(spacing: 4) {
                    Text(entry.word)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(outcome.shortLabel)
                        .font(.title3.bold())
                        .foregroundStyle(outcome.color)
                }
                .id(entry.id)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: entry?.id)
    }
}

extension GameRules.Outcome {
    var shortLabel: String {
        switch self {
        case .correct(let bonus) where bonus >= 2: "+\(points) 意外！"
        case .correct(let bonus) where bonus == 1: "+\(points) いいね"
        case .correct: "+\(points)"
        case .wrong: "×"
        case .duplicate: "もう言った"
        case .unjudged: "判定できず"
        }
    }

    var color: Color {
        switch self {
        case .correct: .green
        case .wrong: .red
        case .duplicate, .unjudged: .secondary
        }
    }
}
