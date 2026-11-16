import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import UniformTypeIdentifiers

/// 手机端解码与 Apple H.264/AAC 编码, 输出可由接收端直接拉取的分片 MP4/HLS.
/// 样本输入只由解码工作线程访问; 分片与进度通过 condition 保护.
final class AirPlayHLSWriter: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private struct Segment { let index: Int; let name: String; let duration: Double; let bytes: Int }
    let directory: URL
    let sourceStart: Double
    private let url: String
    private let headers: String
    private let width: Int
    private let height: Int
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let condition = NSCondition()
    private let token = NativeMediaToken()
    private var segments: [Segment] = []
    private var nextSegment = 0
    private var bytes = 0
    private var allowedUntil = 24.0
    private var ended = false
    private var errorMessage: String?

    init(url: String, headers: [String: String], info: MediaInspection, start: Double, compatible1080: Bool) throws {
        guard info.valid, !info.isHDR else { throw MediaTransportError.failed("本轮投送支持 SDR，HDR / Dolby Vision 不在此次实现范围内") }
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("AirPlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        directory = outputDirectory
        self.url = url; self.headers = MediaInspection.httpHeaders(headers); sourceStart = max(0, start)
        let scale = compatible1080 ? min(1, min(1920.0 / Double(info.width), 1080.0 / Double(info.height))) : 1
        let outputWidth = max(2, Int(Double(info.width) * scale) / 2 * 2)
        let outputHeight = max(2, Int(Double(info.height) * scale) / 2 * 2)
        let outputWriter = AVAssetWriter(contentType: .mpeg4Movie)
        outputWriter.outputFileTypeProfile = .mpeg4AppleHLS
        outputWriter.preferredOutputSegmentInterval = CMTime(seconds: 4, preferredTimescale: 600)
        outputWriter.initialSegmentStartTime = .zero
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: outputWidth, AVVideoHeightKey: outputHeight,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(24_000_000, max(1_500_000, Int(Double(outputWidth * outputHeight) * info.frameRate * 0.09))),
                AVVideoMaxKeyFrameIntervalDurationKey: 4,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        if abs(info.rotation) > 1 { videoInput.transform = CGAffineTransform(rotationAngle: -info.rotation * .pi / 180) }
        let outputAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: outputWidth, kCVPixelBufferHeightKey as String: outputHeight])
        let audioInput: AVAssetWriterInput?
        if info.audioChannels > 0 {
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
            audioInput?.expectsMediaDataInRealTime = false
        } else { audioInput = nil }
        width = outputWidth; height = outputHeight
        writer = outputWriter; video = videoInput; audio = audioInput; adaptor = outputAdaptor
        super.init()
        guard writer.canAdd(video), audio.map({ writer.canAdd($0) }) ?? true else { throw MediaTransportError.failed("设备不支持此投送编码配置") }
        writer.add(video); if let audio { writer.add(audio) }
        writer.delegate = self
    }

    func setPlaybackPosition(_ relativeSeconds: Double) {
        guard relativeSeconds.isFinite else { return }
        condition.lock(); allowedUntil = max(0, relativeSeconds) + 24; condition.broadcast(); condition.unlock()
    }
    func cancel() { token.cancel(); condition.lock(); condition.broadcast(); condition.unlock() }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func run() async {
        guard writer.startWriting() else { fail("无法启动手机端投送编码"); return }
        writer.startSession(atSourceTime: .zero)
        do {
            let result = try await MediaIO.run {
                ANMediaDecode(self.url, self.headers, self.sourceStart, Int32(self.width), Int32(self.height),
                    self.token.pointer, Unmanaged.passUnretained(self).toOpaque(), { context, buffer, seconds in
                        guard let context, let buffer else { return 0 }
                        let output = Unmanaged<AirPlayHLSWriter>.fromOpaque(context).takeUnretainedValue()
                        let pixel = Unmanaged<CVPixelBuffer>.fromOpaque(buffer).takeUnretainedValue()
                        return output.appendVideo(pixel, seconds: seconds) ? 1 : 0
                    }, { context, samples, frames, seconds in
                        guard let context, let samples else { return 0 }
                        return Unmanaged<AirPlayHLSWriter>.fromOpaque(context).takeUnretainedValue()
                            .appendAudio(samples, frames: frames, seconds: seconds) ? 1 : 0
                    })
            }
            if token.cancelled { writer.cancelWriting(); return }
            guard result >= 0 else { writer.cancelWriting(); fail("手机端媒体转换失败 (\(result))"); return }
            video.markAsFinished(); audio?.markAsFinished()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting { continuation.resume() }
            }
            condition.lock()
            if writer.status == .completed { ended = true; writePlaylist() }
            else { errorMessage = "投送分片写入失败" }
            condition.broadcast(); condition.unlock()
        } catch { if !token.cancelled { fail("手机端媒体转换中断") } }
    }

    private func waitForInput(_ input: AVAssetWriterInput, seconds: Double) -> Bool {
        condition.lock()
        while seconds > allowedUntil && !token.cancelled { _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5)) }
        condition.unlock()
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !input.isReadyForMoreMediaData {
            if token.cancelled || writer.status != .writing || ProcessInfo.processInfo.systemUptime > deadline { return false }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return !token.cancelled
    }
    private func appendVideo(_ buffer: CVPixelBuffer, seconds: Double) -> Bool {
        guard seconds.isFinite, waitForInput(video, seconds: seconds) else { return false }
        return adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 90_000))
    }
    private func appendAudio(_ samples: UnsafePointer<Float>, frames: Int32, seconds: Double) -> Bool {
        guard let audio else { return true }
        guard frames > 0, seconds.isFinite, waitForInput(audio, seconds: seconds) else { return false }
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format) == noErr, let format else { return false }
        let count = Int(frames) * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: count,
            flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block,
            CMBlockBufferReplaceDataBytes(with: samples, blockBuffer: block, offsetIntoDestination: 0, dataLength: count) == noErr else { return false }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: Int(frames), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample) == noErr, let sample else { return false }
        return audio.append(sample)
    }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        condition.lock(); defer { condition.unlock() }
        guard !token.cancelled else { return }
        do {
            if segmentType == .initialization {
                try segmentData.write(to: directory.appendingPathComponent("init.mp4"), options: .atomic)
            } else {
                let duration = segmentReport?.trackReports.first(where: { $0.mediaType == .video })?.duration.seconds ?? 4
                guard duration.isFinite, duration > 0 else { errorMessage = "投送分片时间戳无效"; return }
                let name = "segment-\(nextSegment).m4s"
                try segmentData.write(to: directory.appendingPathComponent(name), options: .atomic)
                segments.append(Segment(index: nextSegment, name: name, duration: duration, bytes: segmentData.count))
                bytes += segmentData.count; nextSegment += 1
                while bytes > 200 * 1024 * 1024 && segments.count > 3 {
                    let old = segments.removeFirst(); bytes -= old.bytes
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.name))
                }
                writePlaylist()
            }
            condition.broadcast()
        } catch { errorMessage = "投送缓存写入失败" }
    }

    private func writePlaylist() {
        guard let first = segments.first else { return }
        let target = max(1, Int(ceil(segments.map(\.duration).max() ?? 4)))
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:\(first.index)\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        for segment in segments { text += "#EXTINF:\(String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), segment.duration)),\n\(segment.name)\n" }
        if ended { text += "#EXT-X-ENDLIST\n" }
        do { try Data(text.utf8).write(to: directory.appendingPathComponent("index.m3u8"), options: .atomic) }
        catch { errorMessage = "投送播放列表写入失败" }
    }
    private func fail(_ message: String) { condition.lock(); errorMessage = message; condition.broadcast(); condition.unlock() }
    private func failure() -> String? { condition.lock(); defer { condition.unlock() }; return errorMessage }

    func resource(_ path: String) async throws -> any MediaByteSource {
        guard path == "index.m3u8" || path == "init.mp4" ||
            (path.hasPrefix("segment-") && path.hasSuffix(".m4s") && !path.contains("/")) else { throw MediaTransportError.invalidRequest }
        for _ in 0..<600 {
            try Task.checkCancellation()
            if token.cancelled { throw CancellationError() }
            if let error = failure() { throw MediaTransportError.failed(error) }
            let file = directory.appendingPathComponent(path)
            if path == "index.m3u8", let data = try? Data(contentsOf: file) {
                return MediaDataSource(data: data, contentType: "application/vnd.apple.mpegurl")
            }
            if path != "index.m3u8", FileManager.default.fileExists(atPath: file.path) { return try MediaFileSource(file) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MediaTransportError.timedOut
    }
    func waitUntilReady() async throws { _ = try await resource("index.m3u8") }
}
