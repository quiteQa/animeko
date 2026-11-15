import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Libmpv
import IOSurface
import OpenGLES
import OpenGLES.ES3
import OpenGLES.EAGLIOSurface

/// 控制队列写入, 渲染队列读取; 渲染队列仅调用明确允许的 mpv 时钟查询.
final class ProbeState: @unchecked Sendable {
    struct Snapshot {
        var generation = UUID()
        var color = FrameProbeColor(primaries: nil, transfer: nil, dolbyVisionProfile: nil)
        var metadataReady = false
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
final class ProbeFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let hostTime: CMTime
    let generation: UUID
    init(buffer: CVPixelBuffer, hostTime: CMTime, generation: UUID) {
        self.buffer = buffer
        self.hostTime = hostTime
        self.generation = generation
    }
}

/// mpv OpenGL render API -> IOSurface-backed CVPixelBuffer. 仅用于 SDR 可行性实验.
/// render queue 与 client queue 独立, 两者之间没有同步等待依赖.
final class MPVPixelBufferOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ani.frame-probe.render", qos: .userInitiated)
    private let scheduleLock = NSLock()
    private var scheduled = false
    private let state: ProbeState
    private let receive: @MainActor (ProbeFrame) -> Void
    private let failure: (String) -> Void
    private var reportedFailure = false
    private var reportedMetadataWait = false
    private var reportedOutput = false
    private var context: EAGLContext?
    private var renderer: OpaquePointer?
    private var clockHandle: OpaquePointer?
    private var pool: CVPixelBufferPool?
    private var framebuffer: GLuint = 0
    private var callback: Unmanaged<Callback>?
    private var closed = false
    static let width = 640
    static let height = 360

    init(state: ProbeState, receive: @escaping @MainActor (ProbeFrame) -> Void, failure: @escaping (String) -> Void) {
        self.state = state
        self.receive = receive
        self.failure = failure
    }

    private final class Callback {
        weak var output: MPVPixelBufferOutput?
        init(_ output: MPVPixelBufferOutput) { self.output = output }
    }

    func initialize(handle: OpaquePointer, completion: @escaping (String?) -> Void) {
        queue.async {
            do {
                try self.create(handle: handle)
                completion(nil)
            } catch {
                self.releaseResources()
                completion(error.localizedDescription)
            }
            EAGLContext.setCurrent(nil)
        }
    }

    private func create(handle: OpaquePointer) throws {
        clockHandle = handle
        guard let context = EAGLContext(api: .openGLES3), EAGLContext.setCurrent(context) else {
            throw ProbeFailure("EAGLContext 不可用")
        }
        self.context = context
        if let renderer = glGetString(GLenum(GL_RENDERER)) {
            print("[frame-probe] OpenGL renderer: \(String(cString: renderer))")
        }
        let attributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: Self.width,
            kCVPixelBufferHeightKey as String: Self.height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferOpenGLESCompatibilityKey as String: true,
            kCVPixelBufferIOSurfaceOpenGLESFBOCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        try check(CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool), "pixel buffer pool")
        glGenFramebuffers(1, &framebuffer)
        var initParams = mpv_opengl_init_params(get_proc_address: { _, name in
            guard let name else { return nil }
            return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        }, get_proc_address_ctx: nil)
        let status = "opengl".withCString { api in
            withUnsafeMutablePointer(to: &initParams) { gl in
                var parameters = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: gl),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                return mpv_render_context_create(&renderer, handle, &parameters)
            }
        }
        guard status >= 0, let renderer else { throw ProbeFailure("mpv OpenGL render context 创建失败 (\(status))") }
        let callback = Unmanaged.passRetained(Callback(self))
        self.callback = callback
        mpv_render_context_set_update_callback(renderer, { pointer in
            guard let pointer else { return }
            Unmanaged<Callback>.fromOpaque(pointer).takeUnretainedValue().output?.requestFrame()
        }, callback.toOpaque())
    }

    func requestFrame() {
        scheduleLock.lock()
        guard !scheduled else { scheduleLock.unlock(); return }
        scheduled = true
        scheduleLock.unlock()
        queue.async {
            self.scheduleLock.lock()
            self.scheduled = false
            self.scheduleLock.unlock()
            guard !self.closed, let context = self.context, EAGLContext.setCurrent(context) else { return }
            defer { EAGLContext.setCurrent(nil) }
            self.render()
        }
    }

    private func render() {
        guard let renderer, let clockHandle, let pool, let context else { return }
        let updates = mpv_render_context_update(renderer)
        guard updates & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
        let snapshot = state.read()
        guard snapshot.metadataReady, snapshot.color.verdict == .sdr else {
            if !reportedMetadataWait {
                print("[frame-probe] waiting for allowed decoded color: \(snapshot.color)")
                reportedMetadataWait = true
            }
            skip(renderer)
            return
        }
        var pixelBuffer: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: 3] as CFDictionary
        let allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limit, &pixelBuffer)
        guard allocation == kCVReturnSuccess, let pixelBuffer else {
            if allocation != kCVReturnWouldExceedAllocationThreshold { fail("pixel buffer allocation: \(allocation)") }
            skip(renderer)
            return
        }
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            fail("pixel buffer 没有 IOSurface")
            skip(renderer)
            return
        }
        var texture: GLuint = 0
        glGenTextures(1, &texture)
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        defer {
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
            glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), 0, 0)
            glBindTexture(GLenum(GL_TEXTURE_2D), 0)
            glDeleteTextures(1, &texture)
        }
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GLint(GL_LINEAR))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GLint(GL_LINEAR))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLint(GL_CLAMP_TO_EDGE))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLint(GL_CLAMP_TO_EDGE))
        let mapped = context.texImageIOSurface(
            surface, target: .init(GL_TEXTURE_2D), internalFormat: .init(GL_RGBA),
            width: UInt32(Self.width), height: UInt32(Self.height),
            format: .init(GL_BGRA), type: .init(GL_UNSIGNED_BYTE), plane: 0
        )
        guard mapped else {
            fail("EAGL IOSurface texture mapping: GL error \(glGetError())")
            skip(renderer)
            return
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)
        let framebufferStatus = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        guard framebufferStatus == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            fail("OpenGL framebuffer incomplete: \(framebufferStatus)")
            skip(renderer)
            return
        }
        var frameInfo = mpv_render_frame_info()
        withUnsafeMutablePointer(to: &frameInfo) { pointer in
            let infoParam = mpv_render_param(type: MPV_RENDER_PARAM_NEXT_FRAME_INFO, data: pointer)
            _ = mpv_render_context_get_info(renderer, infoParam)
        }
        var fbo = mpv_opengl_fbo(fbo: Int32(framebuffer), w: Int32(Self.width), h: Int32(Self.height), internal_format: Int32(GL_RGBA8))
        let status = withUnsafeMutablePointer(to: &fbo) { pointer in
            var parameters = [
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: pointer),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            return mpv_render_context_render(renderer, &parameters)
        }
        // IOSurface 交给 CoreMedia 前等待 GPU 完成写入; 不进行像素截图或 CPU 回读.
        glFinish()
        guard status >= 0 else { fail("mpv_render_context_render: \(status)"); return }
        if !reportedOutput { print("[frame-probe] first IOSurface frame rendered"); reportedOutput = true }
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let seconds = FrameProbeClock.presentationSeconds(targetMicroseconds: frameInfo.target_time, mpvNowMicroseconds: mpv_get_time_us(clockHandle), hostNowSeconds: now)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        let frame = ProbeFrame(buffer: pixelBuffer, hostTime: CMTime(seconds: seconds, preferredTimescale: 1_000_000), generation: snapshot.generation)
        let receive = receive
        Task { @MainActor in receive(frame) }
    }

    private func fail(_ message: String) {
        guard !reportedFailure else { return }
        reportedFailure = true
        failure(message)
    }

    private func skip(_ renderer: OpaquePointer) {
        var skip: Int32 = 1
        withUnsafeMutablePointer(to: &skip) { pointer in
            var parameters = [
                mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: pointer),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            _ = mpv_render_context_render(renderer, &parameters)
        }
    }

    func close(completion: @escaping () -> Void) {
        queue.async {
            self.closed = true
            if let context = self.context { EAGLContext.setCurrent(context) }
            self.releaseResources()
            EAGLContext.setCurrent(nil)
            completion()
        }
    }

    private func releaseResources() {
        if let renderer {
            mpv_render_context_set_update_callback(renderer, nil, nil)
            mpv_render_context_free(renderer)
        }
        renderer = nil
        clockHandle = nil
        callback?.release()
        callback = nil
        if framebuffer != 0 { glDeleteFramebuffers(1, &framebuffer) }
        framebuffer = 0
        pool = nil
        context = nil
    }

    private func check(_ status: CVReturn, _ operation: String) throws {
        if status != kCVReturnSuccess { throw ProbeFailure("\(operation) 失败 (\(status))") }
    }
}

struct ProbeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
