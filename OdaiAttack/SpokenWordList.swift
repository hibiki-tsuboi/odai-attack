//
//  SpokenWordList.swift
//  OdaiAttack
//

import Foundation
import Observation
import os

/// 声で確定した言葉を受け取り、判定を言葉ごとに並行して送り、結果を言った順に出す。同じ言葉は判定しない。
/// 音声判定画面とゲームで使う。
@Observable
final class SpokenWordList {
    /// 結果は言った順に出すため、前の言葉の判定を待つ。ただしこの時間を過ぎたら待たずに次を出す。
    static let maxRevealWait: Duration = .seconds(1)

    /// これから確定する言葉を判定するときのお題。
    var topic = ""
    /// 確定した言葉（言った順）。
    private(set) var entries: [SpokenEntry] = []
    /// 言葉の結果を出したとき（言った順）と、待ちきれずに先に出した言葉の判定があとから終わったときに呼ぶ。
    @ObservationIgnored var onReveal: ((SpokenEntry) -> Void)?

    private let judge: WordJudge
    private var duplicateKeys: Set<String> = []
    /// 次に結果を出す `entries` の位置。
    private var revealIndex = 0
    private var revealTimer: Task<Void, Never>?

    private static let logger = Logger(subsystem: "jp.hibiki.OdaiAttack", category: "Voice")

    init(judge: WordJudge) {
        self.judge = judge
    }

    /// 判定中の言葉があるか。
    var isJudging: Bool {
        entries.contains { !$0.isSettled }
    }

    func clear() {
        entries = []
        duplicateKeys = []
        revealIndex = 0
        revealTimer?.cancel()
        revealTimer = nil
    }

    func add(_ word: String, speechEndedAt: ContinuousClock.Instant?) {
        guard duplicateKeys.insert(SpokenWords.duplicateKey(word)).inserted else {
            entries.append(SpokenEntry(word: word, speechEndedAt: speechEndedAt, status: .duplicate))
            revealInOrder()
            return
        }
        let entry = SpokenEntry(word: word, speechEndedAt: speechEndedAt, status: .judging)
        entries.append(entry)
        // 判定は言葉ごとに並行して送る
        let topic = topic
        Task {
            let status: SpokenEntry.Status
            do {
                status = .judged(try await judge.judge(word: word, topic: topic))
            } catch {
                status = .failed(error.localizedDescription)
            }
            guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
            entries[index].status = status
            if entries[index].revealedAt != nil {
                onReveal?(entries[index])
            }
            revealInOrder()
        }
        revealInOrder()
    }

    /// 判定がすべて終わるか、`timeout` が過ぎるまで待つ。
    func waitForJudgments(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while isJudging, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// 判定が終わった結果を言った順に出す。前の言葉の判定が終わるまで後の言葉の結果は出さないが、
    /// 前の言葉が `maxRevealWait` を過ぎても終わらなければ、待たずに次へ進む。
    private func revealInOrder() {
        revealTimer?.cancel()
        revealTimer = nil
        let now = ContinuousClock.now
        while revealIndex < entries.count {
            let entry = entries[revealIndex]
            let deadline = entry.confirmedAt + Self.maxRevealWait
            guard entry.isSettled || now >= deadline else {
                revealTimer = Task { [weak self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    guard !Task.isCancelled else { return }
                    self?.revealInOrder()
                }
                return
            }
            entries[revealIndex].revealedAt = now
            logReveal(entries[revealIndex])
            onReveal?(entries[revealIndex])
            revealIndex += 1
        }
    }

    private func logReveal(_ entry: SpokenEntry) {
        guard case .judged(let judgment) = entry.status else { return }
        if let speechToReveal = entry.speechToReveal {
            Self.logger.info("表示 \(entry.word, privacy: .public): 話し終わりから \(speechToReveal.inMilliseconds, format: .fixed(precision: 0)) ms（判定 \(judgment.latency.inMilliseconds, format: .fixed(precision: 0)) ms）")
        } else {
            Self.logger.info("表示 \(entry.word, privacy: .public)（判定 \(judgment.latency.inMilliseconds, format: .fixed(precision: 0)) ms）")
        }
    }
}

/// 声で言って確定した1つの言葉と、その判定の状態。
nonisolated struct SpokenEntry: Identifiable, Sendable {
    nonisolated enum Status: Sendable {
        /// すでに言った言葉なので判定しない。
        case duplicate
        case judging
        case judged(WordJudgment)
        case failed(String)
    }

    let id = UUID()
    let word: String
    /// 言葉が確定した時刻。
    let confirmedAt = ContinuousClock.now
    /// 無音で区切れたときの、話し終わったおおよその時刻。
    let speechEndedAt: ContinuousClock.Instant?
    var status: Status
    /// 結果を画面に出した時刻。言った順に出すため、判定が終わってもすぐには出さないことがある。
    var revealedAt: ContinuousClock.Instant?

    var isSettled: Bool {
        if case .judging = status { false } else { true }
    }

    /// 話し終わってから結果を画面に出すまでの時間。
    var speechToReveal: Duration? {
        guard let speechEndedAt, let revealedAt else { return nil }
        return revealedAt - speechEndedAt
    }
}
