//
//  Formatting.swift
//  OdaiAttack
//

import Foundation

nonisolated extension Duration {
    /// 秒（小数あり）。
    var inSeconds: Double { self / .seconds(1) }
    /// ミリ秒（小数あり）。
    var inMilliseconds: Double { self / .milliseconds(1) }
    /// 整数に丸めたミリ秒（例: "312"）。
    var roundedMilliseconds: String { String(Int(inMilliseconds.rounded())) }
    var millisecondsText: String { "\(roundedMilliseconds) ms" }
}

nonisolated extension Double {
    var twoDecimals: String { formatted(.number.precision(.fractionLength(2))) }
}
