import CoreMedia
import CoreVideo
import Foundation
import Libmpv

/// 控制队列写入, 渲染队列读取; 渲染队列仅调用明确允许的 mpv 时钟查询.
final class VideoFrameState: @unchecked Sendable {
    struct Snapshot {
        var generation = UUID()
        var color = FrameProbeColor(primaries: nil, transfer: nil, dolbyVisionProfile: nil)
        var metadataReady = false
        var width = 1920
        var height = 1080
        var epoch = UUID()
        var position: Double = 0
        var duration: Double = 0
        var paused = true
    }
    private let lock = NSLock()
    private var snapshot = Snapshot()
    func read() -> Snapshot { lock.lock(); defer { lock.unlock() }; return snapshot }
    func update(_ change: (inout Snapshot) -> Void) { lock.lock(); defer { lock.unlock() }; change(&snapshot) }
}

/// 每个 packet 持有池中的一个 buffer; 交给显示层后由 CoreMedia 管理生命周期.
final class VideoFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let hostTime: CMTime
    let generation: UUID
    let epoch: UUID
    init(buffer: CVPixelBuffer, hostTime: CMTime, generation: UUID, epoch: UUID) {
        self.buffer = buffer
        self.hostTime = hostTime
        self.generation = generation
        self.epoch = epoch
    }
}

/// mpv 软件 render API 直接写入 IOSurface-backed CVPixelBuffer, 由系统显示与画中画持有。
/// 应用进入后台时不执行 OpenGL/Metal 命令; 字幕与 OSD 由同一个 mpv render API 合成。
final class MPVSampleBufferOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ani.mpv.samplebuffer", qos: .userInitiated)
    private let scheduleLock = NSLock()
    private var scheduled = false
    private var forceRequested = false
    private let state: VideoFrameState
    private let receive: @MainActor (VideoFrame) -> Void
    private let failure: (String) -> Void
    private var renderer: OpaquePointer?
    private var clockHandle: OpaquePointer?
    private var pool: CVPixelBufferPool?
    private var dimensions = (width: 0, height: 0)
    private var closed = false
    private var callback: Unmanaged<Callback>?
    private var reportedFailure = false

    private final class Callback {
        weak var output: MPVSampleBufferOutput?
        init(_ output: MPVSampleBufferOutput) { self.output = output }
    }
    init(state: VideoFrameState, receive: @escaping @MainActor (VideoFrame) -> Void, failure: @escaping (String) -> Void) {
        self.state = state; self.receive = receive; self.failure = failure
    }
    func initialize(handle: OpaquePointer, completion: @escaping (String?) -> Void) {
        queue.async {
            self.clockHandle = handle
            let status = "sw".withCString { api in
                var parameters = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                return mpv_render_context_create(&self.renderer, handle, &parameters)
            }
            guard status >= 0, let renderer = self.renderer else {
                completion("mpv 系统视频缓冲输出初始化失败 (\(status))"); return
            }
            let target = Unmanaged.passRetained(Callback(self)); self.callback = target
            mpv_render_context_set_update_callback(renderer, { pointer in
                guard let pointer else { return }
                Unmanaged<Callback>.fromOpaque(pointer).takeUnretainedValue().output?.requestFrame()
            }, target.toOpaque())
            completion(nil)
        }
    }
    func requestFrame(force: Bool = false) {
        scheduleLock.lock()
        forceRequested = forceRequested || force
        guard !scheduled else { scheduleLock.unlock(); return }
        scheduled = true; scheduleLock.unlock()
        queue.async {
            self.scheduleLock.lock()
            let force = self.forceRequested
            self.forceRequested = false; self.scheduled = false; self.scheduleLock.unlock()
            if !self.closed { self.render(force: force) }
        }
    }
    private func render(force: Bool) {
        guard let renderer, let clockHandle else { return }
        let updates = mpv_render_context_update(renderer)
        guard force || updates & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
        let snapshot = state.read()
        guard snapshot.metadataReady, snapshot.color.verdict == .sdr else { skip(renderer); return }
        let width = snapshot.width, height = snapshot.height
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { skip(renderer); return }
        if dimensions.width != width || dimensions.height != height || pool == nil {
            pool = nil
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            guard status == kCVReturnSuccess else { fail("创建视频缓冲池失败 (\(status))"); skip(renderer); return }
            dimensions = (width, height)
        }
        guard let pool else { skip(renderer); return }
        var buffer: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: 3] as CFDictionary
        let allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limit, &buffer)
        guard allocation == kCVReturnSuccess, let buffer else { skip(renderer); return }
        let lock = CVPixelBufferLockBaseAddress(buffer, [])
        guard lock == kCVReturnSuccess else { fail("视频缓冲区写入失败"); skip(renderer); return }
        var frameInfo = mpv_render_frame_info()
        withUnsafeMutablePointer(to: &frameInfo) {
            _ = mpv_render_context_get_info(renderer, mpv_render_param(type: MPV_RENDER_PARAM_NEXT_FRAME_INFO, data: $0))
        }
        let result: Int32
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            var size = [Int32(width), Int32(height)]
            var stride = CVPixelBufferGetBytesPerRow(buffer)
            result = size.withUnsafeMutableBufferPointer { sizePointer in
                withUnsafeMutablePointer(to: &stride) { stridePointer in
                    "bgra".withCString { format in
                        var parameters = [
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: sizePointer.baseAddress),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: format)),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: stridePointer),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
                            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                        ]
                        return mpv_render_context_render(renderer, &parameters)
                    }
                }
            }
        } else { result = -1 }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard result >= 0 else { fail("mpv 视频帧输出失败 (\(result))"); return }
        let current = state.read()
        guard current.epoch == snapshot.epoch, current.metadataReady, current.color.verdict == .sdr else { return }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let seconds = FrameProbeClock.presentationSeconds(targetMicroseconds: frameInfo.target_time,
            mpvNowMicroseconds: mpv_get_time_us(clockHandle), hostNowSeconds: now)
        let frame = VideoFrame(buffer: buffer, hostTime: CMTime(seconds: seconds, preferredTimescale: 1_000_000),
            generation: snapshot.generation, epoch: snapshot.epoch)
        let receive = receive
        Task { @MainActor in receive(frame) }
    }
    private func fail(_ message: String) {
        guard !reportedFailure else { return }; reportedFailure = true; failure(message)
    }
    private func skip(_ renderer: OpaquePointer) {
        var skip: Int32 = 1
        withUnsafeMutablePointer(to: &skip) { pointer in
            var parameters = [mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: pointer),
                              mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
            _ = mpv_render_context_render(renderer, &parameters)
        }
    }
    func close(completion: @escaping () -> Void) {
        queue.async {
            self.closed = true
            if let renderer = self.renderer {
                mpv_render_context_set_update_callback(renderer, nil, nil)
                mpv_render_context_free(renderer)
            }
            self.renderer = nil; self.clockHandle = nil
            self.callback?.release(); self.callback = nil; self.pool = nil
            completion()
        }
    }
}
