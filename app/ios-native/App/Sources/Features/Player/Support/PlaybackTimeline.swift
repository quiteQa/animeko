import Foundation

/// mpv 媒体秒与单调 host clock 的映射; 暂停时媒体时钟停止, 倍速同时作用于帧时间戳与 PiP timebase.
struct PlaybackTimeline: Sendable {
    private(set) var mediaAnchor: Double = 0
    private(set) var hostAnchor: Double = 0
    private(set) var rate: Double = 0
    private(set) var duration: Double = 0
    private var anchored = false

    @discardableResult
    mutating func update(position: Double, duration: Double, speed: Double, paused: Bool, hostTime: Double) -> Bool {
        guard position.isFinite, hostTime.isFinite, speed.isFinite, speed > 0 else { return false }
        if duration.isFinite { self.duration = max(0, duration) }
        let position = bounded(position)
        let nextRate = paused ? 0 : speed
        let resync = !anchored || nextRate != rate || abs(mediaTime(at: hostTime) - position) > 0.15
        if resync {
            mediaAnchor = position
            hostAnchor = hostTime
            rate = nextRate
            anchored = true
        }
        return resync
    }

    func mediaTime(at hostTime: Double) -> Double {
        guard anchored, hostTime.isFinite else { return mediaAnchor }
        return bounded(mediaAnchor + (hostTime - hostAnchor) * rate)
    }

    func seekTarget(position: Double, offset: Double) -> Double? {
        guard position.isFinite, offset.isFinite, (position + offset).isFinite else { return nil }
        return bounded(position + offset)
    }

    private func bounded(_ value: Double) -> Double { duration > 0 ? min(duration, max(0, value)) : max(0, value) }
}
