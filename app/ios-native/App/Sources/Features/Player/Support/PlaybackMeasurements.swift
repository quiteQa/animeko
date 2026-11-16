import Foundation

/// 有界的播放性能记录. 只记录耗时, 不保留 URL、请求头或媒体名称.
struct PlaybackMeasurements: Codable, Sendable {
    private(set) var firstFrames: [Double] = []
    private(set) var seeks: [Double] = []
    private(set) var failures = 0
    private var loadingSince: Double?
    private var seekingSince: Double?

    mutating func beginLoad(at time: Double) { loadingSince = time; seekingSince = nil }
    mutating func beginSeek(at time: Double) { seekingSince = time }
    mutating func ready(at time: Double) {
        if let start = loadingSince, time >= start { Self.append(time - start, to: &firstFrames); loadingSince = nil }
        if let start = seekingSince, time >= start { Self.append(time - start, to: &seeks); seekingSince = nil }
    }
    mutating func failed() { failures += 1; loadingSince = nil; seekingSince = nil }
    mutating func stop() { loadingSince = nil; seekingSince = nil }
    private static func append(_ value: Double, to list: inout [Double]) {
        guard value.isFinite else { return }
        list.append(value)
        if list.count > 100 { list.removeFirst(list.count - 100) }
    }
}
