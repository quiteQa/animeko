import Foundation

/// BGRA8 帧输出实验的输入限制. 未知色彩信息不能当作 SDR.
struct FrameProbeColor: Equatable, Sendable {
    let primaries: String?
    let transfer: String?
    let dolbyVisionProfile: Int?

    enum Verdict: Equatable, Sendable {
        case sdr
        case blocked(String)
    }

    var verdict: Verdict {
        if let profile = dolbyVisionProfile {
            return .blocked("Dolby Vision Profile \(profile) 需要原生高位深帧输出, BGRA8 实验不处理")
        }
        let transfer = transfer?.lowercased()
        let primaries = primaries?.lowercased()
        if ["pq", "smpte2084", "hlg", "arib-std-b67"].contains(transfer ?? "") || primaries == "bt.2020" {
            return .blocked("HDR 需要高位深与元数据链路, BGRA8 实验不处理")
        }
        let sdrTransfers: Set<String> = ["bt.1886", "bt.709", "srgb", "gamma2.2", "gamma2.4", "gamma2.8"]
        let sdrPrimaries: Set<String> = ["bt.709", "bt.601-525", "bt.601-625"]
        guard let transfer, let primaries, sdrTransfers.contains(transfer), sdrPrimaries.contains(primaries) else {
            return .blocked("色彩信息未知或未经验证, 不允许隐式转换为 SDR")
        }
        return .sdr
    }
}

/// 将 mpv 的绝对微秒时钟映射到系统 host clock, 用于输出帧的显示时间戳.
enum FrameProbeClock {
    static func presentationSeconds(targetMicroseconds: Int64, mpvNowMicroseconds: Int64, hostNowSeconds: Double) -> Double {
        guard targetMicroseconds > 0 else { return hostNowSeconds }
        // 先转 Double 再做减法, 避免损坏的时间戳溢出 Int64.
        let offset = (Double(targetMicroseconds) - Double(mpvNowMicroseconds)) / 1_000_000
        guard offset.isFinite, abs(offset) < 1 else { return hostNowSeconds }
        return hostNowSeconds + offset
    }
}
