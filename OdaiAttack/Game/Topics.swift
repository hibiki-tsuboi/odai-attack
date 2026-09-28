//
//  Topics.swift
//  OdaiAttack
//

import Foundation

/// ゲームのお題。家族や友達と遊べる、誰でも答えやすいもの。
nonisolated enum Topics {
    static let all = [
        "赤いもの",
        "黄色いもの",
        "丸いもの",
        "四角いもの",
        "甘いもの",
        "冷たいもの",
        "冬に使うもの",
        "夏といえば",
        "台所にあるもの",
        "学校にあるもの",
        "お祭りで見かけるもの",
        "朝ごはんに食べるもの",
        "動物",
        "海にいる生き物",
        "空を飛ぶもの",
        "果物",
        "野菜",
        "乗り物",
        "スポーツ",
        "楽器",
    ]

    /// `current` 以外からランダムに選ぶ。
    static func random(excluding current: String) -> String {
        all.filter { $0 != current }.randomElement() ?? all[0]
    }
}
