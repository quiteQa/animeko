import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// 在 mpv 的色彩推断之前读取编码层元数据; 未声明的字段保持未知.
enum ProbeInputColor {
    static func inspect(_ url: URL) throws -> FrameProbeColor {
        var context: UnsafeMutablePointer<AVFormatContext>?
        let status = avformat_open_input(&context, url.path, nil, nil)
        guard status >= 0, let opened = context else { throw ProbeFailure("无法读取样本容器 (\(status))") }
        defer { avformat_close_input(&context) }
        let info = avformat_find_stream_info(opened, nil)
        guard info >= 0 else { throw ProbeFailure("无法读取视频轨道 (\(info))") }
        let index = av_find_best_stream(opened, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard index >= 0, let streams = opened.pointee.streams,
              let stream = streams[Int(index)], let parameters = stream.pointee.codecpar else {
            throw ProbeFailure("样本没有可读取的视频轨道")
        }
        let parametersValue = parameters.pointee
        let primaries: String?
        switch parametersValue.color_primaries {
        case AVCOL_PRI_BT709: primaries = "bt.709"
        case AVCOL_PRI_SMPTE170M: primaries = "bt.601-525"
        case AVCOL_PRI_BT470BG: primaries = "bt.601-625"
        case AVCOL_PRI_BT2020: primaries = "bt.2020"
        default: primaries = nil
        }
        let transfer: String?
        switch parametersValue.color_trc {
        case AVCOL_TRC_BT709, AVCOL_TRC_SMPTE170M: transfer = "bt.709"
        case AVCOL_TRC_GAMMA22: transfer = "gamma2.2"
        case AVCOL_TRC_GAMMA28: transfer = "gamma2.8"
        case AVCOL_TRC_IEC61966_2_1: transfer = "srgb"
        case AVCOL_TRC_SMPTE2084: transfer = "pq"
        case AVCOL_TRC_ARIB_STD_B67: transfer = "hlg"
        default: transfer = nil
        }
        var profile: Int?
        if let side = av_packet_side_data_get(parametersValue.coded_side_data, parametersValue.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF),
           UInt64(side.pointee.size) >= UInt64(MemoryLayout<AVDOVIDecoderConfigurationRecord>.size), let data = side.pointee.data {
            profile = Int(UnsafeRawPointer(data).assumingMemoryBound(to: AVDOVIDecoderConfigurationRecord.self).pointee.dv_profile)
        }
        return FrameProbeColor(primaries: primaries, transfer: transfer, dolbyVisionProfile: profile)
    }
}
