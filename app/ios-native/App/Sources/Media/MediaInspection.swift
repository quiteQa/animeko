import Foundation

final class NativeMediaToken: @unchecked Sendable {
    let pointer = ANMediaTokenCreate()!
    var cancelled: Bool { ANMediaTokenIsCancelled(pointer) != 0 }
    func cancel() { ANMediaTokenCancel(pointer) }
    deinit { ANMediaTokenDestroy(pointer) }
}

struct MediaInspection: Sendable {
    let width: Int
    let height: Int
    let duration: Double
    let frameRate: Double
    let rotation: Double
    let audioChannels: Int
    let primaries: Int32
    let transfer: Int32
    let dolbyProfile: Int32
    var isHDR: Bool { transfer == 16 || transfer == 18 || dolbyProfile > 0 }
    var valid: Bool { width > 0 && height > 0 && width <= 4096 && height <= 4096 }

    static func httpHeaders(_ headers: [String: String]) -> String {
        let safe = MPVRequestHeaders(headers)
        var fields = safe.fields
        if !safe.userAgent.isEmpty { fields.append("User-Agent: \(safe.userAgent)") }
        if !safe.referrer.isEmpty { fields.append("Referer: \(safe.referrer)") }
        return fields.isEmpty ? "" : fields.joined(separator: "\r\n") + "\r\n"
    }
    static func inspect(url: String, headers: [String: String]) async throws -> Self {
        let token = NativeMediaToken()
        let headers = httpHeaders(headers)
        return try await withTaskCancellationHandler {
            try await MediaIO.run {
                var info = ANMediaInfo()
                let status = ANMediaProbe(url, headers, token.pointer, &info)
                if token.cancelled { throw CancellationError() }
                guard status >= 0 else { throw MediaTransportError.failed("无法读取媒体信息 (\(status))") }
                return Self(width: Int(info.width), height: Int(info.height), duration: max(0, info.duration),
                    frameRate: info.frame_rate.isFinite && info.frame_rate > 0 ? info.frame_rate : 24,
                    rotation: info.rotation.isFinite ? info.rotation : 0, audioChannels: Int(info.audio_channels),
                    primaries: info.primaries, transfer: info.transfer, dolbyProfile: info.dolby_profile)
            }
        } onCancel: { token.cancel() }
    }
}

struct MediaDataSource: MediaByteSource {
    let data: Data
    let contentType: String
    var size: Int64 { Int64(data.count) }
    func read(offset: Int64, count: Int) async throws -> Data {
        guard offset >= 0, offset <= size else { throw MediaTransportError.invalidRequest }
        return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + count))
    }
}
