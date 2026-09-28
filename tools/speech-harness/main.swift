// 声の区切り（SpeechWordRecognizer）を Mac で試す。
// 合成音声（say コマンド）で作った単語を、iPhone のマイクと同じ 100 ms ずつ・実時間のペースで流し、確定した言葉を表示する。
// シミュレーターには日本語の音声入力モデルが無いので、実機以外で区切りを確かめるときに使う。
//
// 使い方: run.sh [単語間の無音ms] [雑音dBFS か off] [単語...]

import AVFoundation
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let pauseMs = arguments.first.flatMap(Int.init) ?? 400
let noiseDB: Float? = arguments.count > 1 ? (arguments[1] == "off" ? nil : Float(arguments[1])) : -60
let spoken = arguments.count > 2
    ? Array(arguments.dropFirst(2))
    : ["りんご", "トマト", "郵便ポスト", "いちご", "消防車", "金魚", "ロケット", "サッカー", "きって", "コップ"]

// 単語ごとに音声ファイルを作る
let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("speech-harness-\(ProcessInfo.processInfo.processIdentifier)")
try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDirectory) }
var files: [URL] = []
for (index, word) in spoken.enumerated() {
    let url = workDirectory.appendingPathComponent("w\(index).wav")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Kyoko", "--file-format=WAVE", "--data-format=LEI16@16000", "-o", url.path, word]
    try say.run()
    say.waitUntilExit()
    files.append(url)
}

let clock = ContinuousClock()
let recognizer = try await SpeechWordRecognizer.make()
let start = clock.now
var wordEnds: [ContinuousClock.Instant] = []
var received: [String] = []

func milliseconds(_ duration: Duration) -> String { String(format: "%5.0f", duration.inMilliseconds) }

let printer = Task {
    for await event in recognizer.events {
        guard case .words(let words, let speechEndedAt) = event else { continue }
        received += words
        let now = clock.now
        let sinceSpeechEnd = speechEndedAt.map { "話し終わりから \(milliseconds(now - $0)) ms" } ?? "無音以外の理由で確定"
        print("\(milliseconds(now - start)) 確定 \(words)（\(sinceSpeechEnd)）")
    }
}

var fedSeconds = 0.0
func feed(_ buffer: AVAudioPCMBuffer) async throws {
    if let noiseDB, let samples = buffer.floatChannelData?[0] {
        let amplitude = pow(10, noiseDB / 20) * Float(3).squareRoot()  // 一様乱数の RMS を noiseDB にする
        for index in 0..<Int(buffer.frameLength) {
            samples[index] += Float.random(in: -amplitude...amplitude)
        }
    }
    recognizer.append(AVReadOnlyAudioPCMBuffer(copying: buffer))
    fedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
    try await clock.sleep(until: start + .seconds(fedSeconds))
}

func feedSilence(seconds: Double, format: AVAudioFormat) async throws {
    let chunk = AVAudioFrameCount(format.sampleRate / 10)
    for _ in 0..<Int((seconds * 10).rounded()) {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
        buffer.frameLength = chunk
        try await feed(buffer)
    }
}

var format: AVAudioFormat?
for (index, url) in files.enumerated() {
    let file = try AVAudioFile(forReading: url)
    format = file.processingFormat
    let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
    while file.framePosition < file.length {
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
        try file.read(into: buffer, frameCount: chunk)
        try await feed(buffer)
    }
    print("\(milliseconds(clock.now - start)) 「\(spoken[index])」の音声が終わり")
    try await feedSilence(seconds: Double(pauseMs) / 1000, format: file.processingFormat)
}
if let format {
    try await feedSilence(seconds: 1, format: format)
}
await recognizer.finish()
await printer.value

print("言った言葉:   \(spoken)")
print("確定した言葉: \(received)")
