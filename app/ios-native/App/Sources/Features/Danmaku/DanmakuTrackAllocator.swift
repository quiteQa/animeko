import CoreGraphics
import Foundation

/// 弹幕轨道分配. 纯逻辑, 不依赖 UIKit:
///
/// - 滚动弹幕从右向左匀速穿过屏幕, 用时固定为 `floatingDuration`, 越长的弹幕速度越快.
///   新弹幕放进某条轨道的条件是: 前一条已完全进入屏幕, 且新弹幕在前一条离开屏幕之前追不上它.
/// - 顶部/底部弹幕居中静止 `fixedDuration` 秒, 同一轨道同一时刻只有一条.
/// - 没有可用轨道时丢弃该弹幕, 而不是重叠显示.
struct DanmakuTrackAllocator {
    struct Config {
        var floatingTrackCount: Int
        var fixedTrackCount: Int
        var viewportWidth: CGFloat
        var floatingDuration: TimeInterval = 8
        var fixedDuration: TimeInterval = 5
    }

    private struct FloatingOccupant {
        let start: TimeInterval
        let width: CGFloat
        let speed: CGFloat
    }

    let config: Config
    private var floating: [FloatingOccupant?]
    private var top: [TimeInterval?]
    private var bottom: [TimeInterval?]

    init(config: Config) {
        self.config = config
        floating = Array(repeating: nil, count: max(config.floatingTrackCount, 0))
        top = Array(repeating: nil, count: max(config.fixedTrackCount, 0))
        bottom = Array(repeating: nil, count: max(config.fixedTrackCount, 0))
    }

    /// 滚动弹幕的速度 (点/秒).
    func speed(forWidth width: CGFloat) -> CGFloat {
        (config.viewportWidth + width) / CGFloat(config.floatingDuration)
    }

    /// 为宽度为 `width` 的滚动弹幕在 `time` 时刻分配轨道.
    mutating func allocateFloating(width: CGFloat, at time: TimeInterval) -> Int? {
        let speed = speed(forWidth: width)
        for index in floating.indices {
            guard let previous = floating[index] else {
                floating[index] = FloatingOccupant(start: time, width: width, speed: speed)
                return index
            }
            let elapsed = CGFloat(time - previous.start)
            // 前一条的尾部是否已经进入屏幕右边缘
            let previousFullyEntered = elapsed * previous.speed >= previous.width
            // 前一条离开屏幕左边缘的时刻, 与新弹幕头部到达左边缘的时刻
            let previousExit = previous.start + config.floatingDuration
            let newReachesLeftEdge = time + TimeInterval(config.viewportWidth / speed)
            if previousFullyEntered, newReachesLeftEdge >= previousExit {
                floating[index] = FloatingOccupant(start: time, width: width, speed: speed)
                return index
            }
        }
        return nil
    }

    /// 为顶部 (`isTop == true`) 或底部弹幕在 `time` 时刻分配轨道.
    mutating func allocateFixed(isTop: Bool, at time: TimeInterval) -> Int? {
        let duration = config.fixedDuration
        func take(_ tracks: inout [TimeInterval?]) -> Int? {
            for index in tracks.indices {
                if let start = tracks[index], time - start < duration { continue }
                tracks[index] = time
                return index
            }
            return nil
        }
        return isTop ? take(&top) : take(&bottom)
    }

    /// 清空所有轨道, 用于跳转进度或改变尺寸.
    mutating func reset() {
        floating = Array(repeating: nil, count: floating.count)
        top = Array(repeating: nil, count: top.count)
        bottom = Array(repeating: nil, count: bottom.count)
    }
}
