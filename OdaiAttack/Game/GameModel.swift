//
//  GameModel.swift
//  OdaiAttack
//

import Foundation
import Observation

/// ゲーム（フェーズ3）の進行。タイトル → お題とカウントダウン → 声で言う → 結果。
@Observable
final class GameModel {
    enum Phase: Equatable {
        case title
        case preparing(String)
        case countdown(Int)
        case playing
        /// 時間切れのあと、最後の言葉の確定と判定を待っている。
        case finishing
        case result
    }

    /// 結果画面で発表する「今回のベスト回答」。
    enum BestAnswerState: Equatable {
        /// 正解した言葉が少なくて選ばない。
        case none
        case choosing
        case chosen(BestAnswer)
        case failed(String)
    }

    private(set) var phase = Phase.title
    private(set) var topic = ""
    private(set) var roundEndsAt: ContinuousClock.Instant?
    /// 認識中でまだ確定していない文字列。
    private(set) var partialText = ""
    /// 最後に結果を出した言葉。
    private(set) var latestEntryID: UUID?
    /// 正解の結果を出すたびに増える。画面を光らせるきっかけにする。
    private(set) var correctRevealCount = 0
    private(set) var bestAnswer = BestAnswerState.none
    private(set) var errorMessage: String?

    /// Jev への接続先が設定されていないと nil。
    private let judge: WordJudge?
    private let wordList: SpokenWordList?
    private let audio = AudioIO()
    private var recognizer: SpeechWordRecognizer?
    private var eventsTask: Task<Void, Never>?
    private var roundTask: Task<Void, Never>?
    /// 言葉を数え始めた時刻（スタートの合図）。カウントダウン中は nil。
    private var roundStartedAt: ContinuousClock.Instant?

    init(client: (any JevClient)? = makeConfiguredJevClient()) {
        let judge = client.map { WordJudge(client: $0) }
        self.judge = judge
        wordList = judge.map { SpokenWordList(judge: $0) }
        wordList?.onReveal = { [weak self] entry in
            self?.didReveal(entry)
        }
    }

    var isConnectionMissing: Bool { wordList == nil }

    var canStart: Bool {
        wordList != nil && (phase == .title || phase == .result)
    }

    /// 確定した言葉（言った順）。
    var entries: [SpokenEntry] { wordList?.entries ?? [] }

    var latestEntry: SpokenEntry? {
        entries.last { $0.id == latestEntryID }
    }

    /// 結果を出した言葉の合計点。
    var score: Int {
        entries.filter { $0.revealedAt != nil }.reduce(0) { $0 + GameRules.outcome(for: $1).points }
    }

    var remainingSeconds: Double {
        guard let roundEndsAt else { return GameRules.roundDuration.inSeconds }
        return max((roundEndsAt - .now).inSeconds, 0)
    }

    func start() {
        guard canStart else { return }
        // 前のラウンドがベスト回答を選んでいる途中なら、やめる
        roundTask?.cancel()
        roundTask = Task { await playRound() }
    }

    /// 遊んでいる途中ならやめて、タイトルに戻る。
    func quit() {
        roundTask?.cancel()
        if phase == .result {
            phase = .title
        }
    }

    private func playRound() async {
        guard let wordList else { return }
        errorMessage = nil
        topic = Topics.random(excluding: topic)
        wordList.topic = topic
        wordList.clear()
        latestEntryID = nil
        bestAnswer = .none
        phase = .preparing("準備しています…")
        do {
            try await AudioIO.requestPermissions()
            let recognizer = try await SpeechWordRecognizer.make { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, case .preparing = self.phase else { return }
                    self.phase = .preparing("音声モデルをダウンロードしています（\(Int(progress * 100))%）")
                }
            }
            self.recognizer = recognizer
            eventsTask = Task { [weak self] in
                for await event in recognizer.events {
                    self?.handle(event)
                }
            }
            try audio.start()
            // カウントダウン中から聞いて、周りの騒音レベルを測っておく（この間に言い終えた言葉は数えない）
            try audio.startCapture(feeding: recognizer)
            // 音声が安定して届いてから数え始める（初回はエンジンが一度止まるので、先に鳴らした音が消えないように）
            try await audio.waitForSteadyInput()

            for count in stride(from: GameRules.countdownFrom, through: 1, by: -1) {
                phase = .countdown(count)
                audio.play(.tick)
                try await Task.sleep(for: .seconds(1))
            }

            let startedAt = ContinuousClock.now
            roundStartedAt = startedAt
            roundEndsAt = startedAt + GameRules.roundDuration
            phase = .playing
            audio.play(.start)
            try await Task.sleep(until: startedAt + GameRules.roundDuration, clock: .continuous)

            phase = .finishing
            audio.play(.timeUp)
            try await Task.sleep(for: GameRules.endGrace)
            await stopListening()
            await wordList.waitForJudgments(timeout: GameRules.judgmentWait)
            audio.stop()
            phase = .result
            await chooseBestAnswer()
        } catch {
            await stopListening()
            audio.stop()
            if !(error is CancellationError) {
                errorMessage = SpeechRecognitionError.describe(error)
            }
            phase = .title
        }
    }

    /// 正解した言葉の中から、今回のベスト回答を Jev に選んでもらう。
    private func chooseBestAnswer() async {
        let candidates = entries
            .filter { if case .correct = GameRules.outcome(for: $0) { true } else { false } }
            .map(\.word)
        guard let judge, candidates.count >= GameRules.bestAnswerMinimumCandidates else {
            bestAnswer = .none
            return
        }
        bestAnswer = .choosing
        do {
            let chosen = try await judge.bestAnswer(among: candidates, topic: topic)
            guard !Task.isCancelled else { return }
            bestAnswer = .chosen(chosen)
        } catch {
            guard !Task.isCancelled else { return }
            bestAnswer = .failed(error.localizedDescription)
        }
    }

    /// マイクを止め、止める前に言った言葉まで確定させる。
    private func stopListening() async {
        audio.stopCapture()
        if let recognizer {
            await recognizer.finish()
            self.recognizer = nil
        }
        await eventsTask?.value
        eventsTask = nil
        roundStartedAt = nil
        roundEndsAt = nil
        partialText = ""
    }

    private func handle(_ event: SpeechWordRecognizer.Event) {
        switch event {
        case .partial(let text):
            partialText = roundStartedAt == nil ? "" : text
        case .words(let words, let speechEndedAt):
            // スタートの合図より前に言い終えた言葉は数えない
            guard let roundStartedAt, (speechEndedAt ?? .now) >= roundStartedAt else { return }
            for word in words {
                wordList?.add(word, speechEndedAt: speechEndedAt)
            }
        case .level:
            break
        case .failed(let message):
            errorMessage = message
        }
    }

    private func didReveal(_ entry: SpokenEntry) {
        guard phase == .playing || phase == .finishing else { return }
        latestEntryID = entry.id
        switch GameRules.outcome(for: entry) {
        case .correct:
            correctRevealCount += 1
            audio.play(.correct)
        case .wrong:
            audio.play(.wrong)
        case .duplicate, .unjudged:
            // 重複では音を鳴らさない（効果音を拾って同じ言葉が続いても、音が鳴り続けないように）
            break
        }
    }
}
