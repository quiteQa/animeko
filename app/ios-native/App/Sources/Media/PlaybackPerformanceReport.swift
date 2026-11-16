import Darwin
import Foundation
import UIKit

/// 有界的设备采样, 不记录媒体地址、请求头、账户或内容名称.
@MainActor
final class PlaybackPerformanceReport {
    struct Sample: Codable {
        let uptime: Double
        let residentBytes: UInt64
        let thermalState: Int
        let battery: Float?
        let decodedDrops: Double
        let outputDrops: Double
        let avSync: Double
        let framePoolDrops: Int
    }
    private var samples: [Sample] = []
    func sample(player: MPVPlayer) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        let battery = UIDevice.current.batteryLevel
        samples.append(Sample(uptime: ProcessInfo.processInfo.systemUptime,
            residentBytes: result == KERN_SUCCESS ? info.resident_size : 0,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            battery: battery >= 0 ? battery : nil,
            decodedDrops: player.double("decoder-frame-drop-count") ?? 0,
            outputDrops: player.double("frame-drop-count") ?? 0,
            avSync: player.double("avsync") ?? 0, framePoolDrops: player.framePoolDrops))
        if samples.count > 720 { samples.removeFirst(samples.count - 720) }
    }
    func export(measurements: PlaybackMeasurements) throws -> URL {
        struct Report: Codable {
            let schema: Int
            let generated: Date
            let system: String
            let model: String
            let appVersion: String
            let measurements: PlaybackMeasurements
            let samples: [Sample]
        }
        let report = Report(schema: 1, generated: Date(), system: UIDevice.current.systemVersion, model: UIDevice.current.model,
            appVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "development", measurements: measurements, samples: samples)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("animeko-playback-performance.json")
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }
}
