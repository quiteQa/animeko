import Foundation
import Libmpv

/// 本地样本播放器. client API 与 OpenGL 渲染使用独立队列.
final class FrameProbeEngine: @unchecked Sendable {
    enum Event {
        case metadata(FrameProbeColor)
        case position(Double, Double, Bool)
        case failed(String)
    }
    private let queue = DispatchQueue(label: "ani.frame-probe.client", qos: .userInitiated)
    private let state = ProbeState()
    private let receive: @MainActor (UUID, Event) -> Void
    private let frames: @MainActor (ProbeFrame) -> Void
    private var handle: OpaquePointer?
    private var output: MPVPixelBufferOutput?
    private var callback: Unmanaged<Callback>?
    private var generation = UUID()
    private var expectedEntry: Int64?
    private var activeEntry: Int64?
    private var pendingURL: URL?
    private var renderReady = false
    private var closed = false

    init(receive: @escaping @MainActor (UUID, Event) -> Void, frames: @escaping @MainActor (ProbeFrame) -> Void) {
        self.receive = receive
        self.frames = frames
    }

    private final class Callback {
        weak var engine: FrameProbeEngine?
        init(_ engine: FrameProbeEngine) { self.engine = engine }
    }

    func open(_ url: URL, generation: UUID) {
        queue.async {
            guard !self.closed else { return }
            guard url.isFileURL else { self.emit(.failed("帧输出实验只接收本地文件")); return }
            self.generation = generation
            self.expectedEntry = nil
            self.activeEntry = nil
            self.state.update { $0 = ProbeState.Snapshot(generation: generation) }
            if let handle = self.handle { _ = self.command(["stop"], handle: handle) }
            do {
                let inputColor = try ProbeInputColor.inspect(url)
                self.emit(.metadata(inputColor))
                if case .blocked = inputColor.verdict { return }
            } catch {
                self.emit(.failed(error.localizedDescription))
                return
            }
            self.pendingURL = url
            if self.handle == nil { self.initialize() }
            if self.renderReady { self.loadPending() }
        }
    }

    private func initialize() {
        guard MPVPixelBufferOutput.supportsSurfaceInterop else {
            emit(.failed("模拟器不提供 EAGL IOSurface 输出, 请使用真机验证帧输出与画中画"))
            return
        }
        guard let handle = mpv_create() else { emit(.failed("mpv_create 失败")); return }
        self.handle = handle
        // copy 路径是当前 MPVKit 的 OpenGL 兼容性实验, 不是零复制/HDR 的正式实现.
        for (key, value) in [
            ("vo", "libmpv"), ("hwdec", "videotoolbox-copy"), ("keep-open", "yes"),
            ("idle", "yes"), ("config", "no"), ("load-scripts", "no"),
            ("terminal", "no"), ("target-prim", "bt.709"), ("target-trc", "srgb"),
        ] {
            let result = mpv_set_option_string(handle, key, value)
            if result < 0 { emit(.failed("mpv 配置 \(key) 失败 (\(result))")); return }
        }
        let status = mpv_initialize(handle)
        guard status >= 0 else { emit(.failed("mpv_initialize 失败 (\(status))")); return }
        for (name, format) in [("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE), ("pause", MPV_FORMAT_FLAG)] {
            let result = mpv_observe_property(handle, 0, name, format)
            guard result >= 0 else { emit(.failed("mpv observe 失败 (\(result))")); return }
        }
        let callback = Unmanaged.passRetained(Callback(self))
        self.callback = callback
        mpv_set_wakeup_callback(handle, { pointer in
            guard let pointer else { return }
            let callback = Unmanaged<Callback>.fromOpaque(pointer).takeUnretainedValue()
            callback.engine?.wake()
        }, callback.toOpaque())
        let output = MPVPixelBufferOutput(state: state, receive: frames, failure: { [weak self] message in
            guard let self else { return }
            queue.async {
                self.emit(.failed(message))
                if let handle = self.handle { mpv_set_property_string(handle, "pause", "yes") }
            }
        })
        self.output = output
        output.initialize(handle: handle) { [weak self] error in
            guard let self else { return }
            queue.async {
                guard !self.closed else { return }
                if let error { self.emit(.failed(error)); return }
                self.renderReady = true
                self.loadPending()
            }
        }
    }

    private func loadPending() {
        guard let handle, let url = pendingURL else { return }
        pendingURL = nil
        let status = command(["loadfile", url.absoluteString, "replace"], handle: handle)
        guard status >= 0 else { emit(.failed("loadfile 失败 (\(status))")); return }
        var entry: Int64 = -1
        guard mpv_get_property(handle, "playlist/0/id", MPV_FORMAT_INT64, &entry) >= 0 else {
            emit(.failed("读取 playlist entry 失败")); return
        }
        expectedEntry = entry
        drainEvents()
    }

    func pause(_ paused: Bool) {
        queue.async {
            if let handle = self.handle { mpv_set_property_string(handle, "pause", paused ? "yes" : "no") }
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        queue.async {
            if let handle = self.handle { _ = self.command(["seek", String(max(0, seconds)), "absolute"], handle: handle) }
        }
    }

    func close(completion: @escaping @MainActor () -> Void) {
        queue.async {
            guard !self.closed else { Task { @MainActor in completion() }; return }
            self.closed = true
            self.state.update { $0.metadataReady = false }
            if let handle = self.handle { mpv_set_wakeup_callback(handle, nil, nil) }
            let finish: () -> Void = {
                self.queue.async {
                    if let handle = self.handle { mpv_terminate_destroy(handle) }
                    self.handle = nil
                    self.output = nil
                    self.callback?.release()
                    self.callback = nil
                    Task { @MainActor in completion() }
                }
            }
            if let output = self.output { output.close(completion: finish) } else { finish() }
        }
    }

    private func wake() { queue.async { if !self.closed { self.drainEvents() } } }

    private func drainEvents() {
        guard let handle else { return }
        while let event = mpv_wait_event(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            switch event.event_id {
            case MPV_EVENT_START_FILE:
                let id = event.data?.assumingMemoryBound(to: mpv_event_start_file.self).pointee.playlist_entry_id
                activeEntry = id == expectedEntry ? id : nil
            case MPV_EVENT_FILE_LOADED, MPV_EVENT_VIDEO_RECONFIG:
                if activeEntry != nil { updateMetadata(handle: handle) }
            case MPV_EVENT_PROPERTY_CHANGE:
                guard activeEntry != nil,
                      let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                      let name = property.name, let data = property.data else { continue }
                let key = String(cString: name)
                state.update { snapshot in
                    if key == "time-pos", property.format == MPV_FORMAT_DOUBLE { snapshot.position = data.assumingMemoryBound(to: Double.self).pointee }
                    if key == "duration", property.format == MPV_FORMAT_DOUBLE { snapshot.duration = data.assumingMemoryBound(to: Double.self).pointee }
                    if key == "pause", property.format == MPV_FORMAT_FLAG { snapshot.paused = data.assumingMemoryBound(to: Int32.self).pointee != 0 }
                }
                let snapshot = state.read()
                let position = snapshot.position.isFinite ? max(0, snapshot.position) : 0
                let duration = snapshot.duration.isFinite ? max(0, snapshot.duration) : 0
                emit(.position(position, duration, snapshot.paused))
            case MPV_EVENT_END_FILE:
                if let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee,
                   end.playlist_entry_id == expectedEntry, end.reason == MPV_END_FILE_REASON_ERROR {
                    emit(.failed("媒体加载失败 (\(end.error))"))
                }
            default: break
            }
        }
    }

    private func updateMetadata(handle: OpaquePointer) {
        let primaries = string("video-params/primaries", handle: handle)
        let transfer = string("video-params/gamma", handle: handle)
        var profile: Int?
        if let count = integer("track-list/count", handle: handle), count > 0, count < 1000 {
            for index in 0..<count where string("track-list/\(index)/type", handle: handle) == "video" {
                var selected: Int32 = 0
                if mpv_get_property(handle, "track-list/\(index)/selected", MPV_FORMAT_FLAG, &selected) >= 0, selected != 0 {
                    profile = integer("track-list/\(index)/dolby-vision-profile", handle: handle).map(Int.init)
                    break
                }
            }
        }
        let color = FrameProbeColor(primaries: primaries, transfer: transfer, dolbyVisionProfile: profile)
        // 初始重配置可能早于解码元数据; 此时只等待, 不猜测色彩.
        guard primaries != nil || transfer != nil || profile != nil else { return }
        state.update { $0.color = color; $0.metadataReady = true }
        emit(.metadata(color))
        if case .blocked = color.verdict { mpv_set_property_string(handle, "pause", "yes") }
        output?.requestFrame()
    }

    private func emit(_ event: Event) {
        switch event {
        case .metadata(let color): print("[frame-probe] metadata \(color) -> \(color.verdict)")
        case .failed(let reason): print("[frame-probe] failure: \(reason)")
        default: break
        }
        let generation = generation
        let receive = receive
        Task { @MainActor in receive(generation, event) }
    }

    private func string(_ name: String, handle: OpaquePointer) -> String? {
        guard let pointer = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(pointer) }
        return String(cString: pointer)
    }

    private func integer(_ name: String, handle: OpaquePointer) -> Int64? {
        var value: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    private func command(_ values: [String], handle: OpaquePointer) -> Int32 {
        let strings = values.map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) }
        pointers.append(nil)
        return mpv_command(handle, &pointers)
    }
}
