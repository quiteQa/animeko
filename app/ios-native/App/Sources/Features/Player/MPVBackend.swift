import Foundation
import Libmpv
import QuartzCore

/// 原生句柄、回调上下文与事件读取全部归 queue 所有. 公共方法只排队或同步读取.
/// Sendable 的保证来自队列隔离; layer 只被保留以覆盖原生输出的完整生命周期.
final class MPVBackend: @unchecked Sendable {
    enum Event {
        case property(String, Double)
        case ready
        case ended
        case failed(String)
    }

    private let queue = DispatchQueue(label: "me.him188.ani.native.mpv", qos: .userInitiated)
    private let layer: CAMetalLayer
    private let receive: @MainActor (UUID, [Event]) -> Void
    private var handle: OpaquePointer?
    private var wakeupTarget: Unmanaged<WakeupTarget>?
    private var initializationError: String?
    private var generation = UUID()
    private var expectedEntry: Int64?
    private var activeEntry: Int64?
    private var reportedEnd = false

    init(layer: CAMetalLayer, receive: @escaping @MainActor (UUID, [Event]) -> Void) {
        self.layer = layer
        self.receive = receive
        queue.async { self.initialize() }
    }

    deinit {
        // 已排队的工作持有 self, 因此释放时没有其他工作还在使用句柄.
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
        }
        wakeupTarget?.release()
    }

    private final class WakeupTarget {
        weak var backend: MPVBackend?
        init(_ backend: MPVBackend) { self.backend = backend }
    }

    private func initialize() {
        guard let handle = mpv_create() else {
            initializationError = "无法创建播放内核"
            return
        }
        self.handle = handle
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        let windowStatus = mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
        guard windowStatus >= 0 else {
            failInitialization(handle, status: windowStatus)
            return
        }
        let required: [(String, String)] = [
            ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"), ("keep-open", "yes"), ("idle", "yes"),
        ]
        for (name, value) in required {
            let status = mpv_set_option_string(handle, name, value)
            guard status >= 0 else {
                failInitialization(handle, status: status)
                return
            }
        }
        for (name, value) in [
            ("video-rotate", "no"), ("ytdl", "no"), ("input-default-bindings", "no"),
            ("cache", "yes"), ("demuxer-max-bytes", "150MiB"), ("demuxer-max-back-bytes", "50MiB"),
            ("subs-fallback", "yes"), ("terminal", "no"), ("config", "no"), ("load-scripts", "no"),
            ("osc", "no"), ("load-stats-overlay", "no"), ("load-console", "no"), ("load-select", "no"),
            ("load-positioning", "no"), ("load-commands", "no"), ("load-context-menu", "no"),
            ("load-auto-profiles", "no"), ("input-media-keys", "no"), ("input-terminal", "no"),
        ] {
            let status = mpv_set_option_string(handle, name, value)
            if status < 0 { Diagnostics.log("mpv: 可选配置 \(name) 失败 (\(status))") }
        }
        // 不启用 mpv 的原始文件日志: 它可能写入带鉴权参数的 URL 与 HTTP 头.
        mpv_request_log_messages(handle, "no")
        let status = mpv_initialize(handle)
        guard status >= 0 else {
            failInitialization(handle, status: status)
            return
        }
        for (name, format) in [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG), ("paused-for-cache", MPV_FORMAT_FLAG),
            ("eof-reached", MPV_FORMAT_FLAG), ("speed", MPV_FORMAT_DOUBLE),
            ("cache-speed", MPV_FORMAT_INT64),
        ] {
            let result = mpv_observe_property(handle, 0, name, format)
            if result < 0 { Diagnostics.log("mpv: 观察 \(name) 失败 (\(result))") }
        }
        let target = Unmanaged.passRetained(WakeupTarget(self))
        wakeupTarget = target
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            let target = Unmanaged<WakeupTarget>.fromOpaque(context).takeUnretainedValue()
            target.backend?.wake()
        }, target.toOpaque())
        Diagnostics.log("mpv: 已就绪")
    }

    private func failInitialization(_ handle: OpaquePointer, status: Int32) {
        initializationError = "播放内核初始化失败 (\(status))"
        self.handle = nil
        mpv_terminate_destroy(handle)
        Diagnostics.log("mpv: 初始化失败 (\(status))")
    }

    func load(url: String, headers: MPVRequestHeaders, start: Double, autoplay: Bool, generation: UUID) {
        queue.async {
            self.generation = generation
            self.expectedEntry = nil
            self.activeEntry = nil
            self.reportedEnd = false
            guard let handle = self.handle else {
                self.deliver([.failed(self.initializationError ?? "播放内核已关闭")])
                return
            }
            // 清理上一文件的事件, 之后按 START_FILE / END_FILE 的 playlist_entry_id 识别文件.
            self.drainEvents()
            let headerStatus = self.setHeaders(headers, handle: handle)
            guard headerStatus >= 0 else {
                self.deliver([.failed("设置视频请求头失败 (\(headerStatus))")])
                return
            }
            var options = ["pause=\(autoplay ? "no" : "yes")"]
            if start > 0 { options.append("start=\(start)") }
            let status = self.command(["loadfile", url, "replace", "-1", options.joined(separator: ",")], handle: handle)
            guard status >= 0 else {
                self.deliver([.failed("加载视频失败 (\(status))")])
                return
            }
            var entry: Int64 = -1
            if mpv_get_property(handle, "playlist/0/id", MPV_FORMAT_INT64, &entry) >= 0 {
                self.expectedEntry = entry
            } else {
                self.deliver([.failed("无法识别播放会话")])
            }
            self.drainEvents()
        }
    }

    private func setHeaders(_ headers: MPVRequestHeaders, handle: OpaquePointer) -> Int32 {
        for (name, value) in [("user-agent", headers.userAgent), ("referrer", headers.referrer)] {
            let status = mpv_set_property_string(handle, name, value)
            if status < 0 { return status }
        }
        // 用 NODE_ARRAY 设置字符串列表, 保留 Cookie 等字段中的逗号.
        let strings = headers.fields.map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var values = strings.map { pointer -> mpv_node in
            var node = mpv_node()
            node.format = MPV_FORMAT_STRING
            node.u.string = pointer
            return node
        }
        return values.withUnsafeMutableBufferPointer { buffer in
            var list = mpv_node_list(num: Int32(buffer.count), values: buffer.baseAddress, keys: nil)
            return withUnsafeMutablePointer(to: &list) { listPointer in
                var node = mpv_node()
                node.format = MPV_FORMAT_NODE_ARRAY
                node.u.list = listPointer
                return mpv_set_property(handle, "http-header-fields", MPV_FORMAT_NODE, &node)
            }
        }
    }

    func stop(generation: UUID) {
        queue.async {
            self.generation = generation
            self.expectedEntry = nil
            self.activeEntry = nil
            if let handle = self.handle { _ = self.command(["stop"], handle: handle) }
            self.drainEvents()
        }
    }

    /// 队列屏障: 返回时此前提交的 stop 等控制命令均已执行.
    func flushCommands() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    func destroy() {
        queue.async {
            self.expectedEntry = nil
            self.activeEntry = nil
            guard let handle = self.handle else { return }
            self.handle = nil
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
            self.wakeupTarget?.release()
            self.wakeupTarget = nil
        }
    }

    func setString(_ name: String, _ value: String) {
        queue.async {
            guard let handle = self.handle else { return }
            let status = mpv_set_property_string(handle, name, value)
            if status < 0 { Diagnostics.log("mpv: 设置 \(name) 失败 (\(status))") }
        }
    }

    func seek(to seconds: Double) {
        queue.async {
            guard let handle = self.handle else { return }
            let status = self.command(["seek", String(seconds), "absolute"], handle: handle)
            if status < 0 { self.deliver([.failed("跳转失败 (\(status))")]) }
        }
    }

    func screenshot(to url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let handle = self.handle else { continuation.resume(returning: false); return }
                let result = self.command(["screenshot-to-file", url.path, "video"], handle: handle)
                continuation.resume(returning: result >= 0 && FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    func string(_ name: String) -> String? {
        queue.sync {
            guard let handle, let value = mpv_get_property_string(handle, name) else { return nil }
            defer { mpv_free(value) }
            return String(cString: value)
        }
    }

    func double(_ name: String) -> Double? {
        queue.sync {
            guard let handle else { return nil }
            var value = 0.0
            return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
        }
    }

    private func command(_ args: [String], handle: OpaquePointer) -> Int32 {
        let strings = args.map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) }
        pointers.append(nil)
        return mpv_command(handle, &pointers)
    }

    private func wake() { queue.async { self.drainEvents() } }

    private func drainEvents() {
        guard let handle else { return }
        var events: [Event] = []
        while let event = mpv_wait_event(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            switch event.event_id {
            case MPV_EVENT_START_FILE:
                let entry = event.data?.assumingMemoryBound(to: mpv_event_start_file.self).pointee.playlist_entry_id
                activeEntry = entry == expectedEntry ? entry : nil
            case MPV_EVENT_END_FILE:
                guard let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee,
                      end.playlist_entry_id == expectedEntry else { continue }
                if end.reason == MPV_END_FILE_REASON_ERROR {
                    events.append(.failed("视频加载失败 (\(end.error))"))
                }
                activeEntry = nil
            case MPV_EVENT_PLAYBACK_RESTART:
                if activeEntry != nil { events.append(.ready) }
            case MPV_EVENT_PROPERTY_CHANGE:
                guard activeEntry != nil,
                      let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                      let namePointer = property.name, let pointer = property.data else { continue }
                let name = String(cString: namePointer)
                let value: Double
                switch property.format {
                case MPV_FORMAT_DOUBLE: value = pointer.assumingMemoryBound(to: Double.self).pointee
                case MPV_FORMAT_FLAG: value = Double(pointer.assumingMemoryBound(to: Int32.self).pointee)
                case MPV_FORMAT_INT64: value = Double(pointer.assumingMemoryBound(to: Int64.self).pointee)
                default: continue
                }
                if name == "eof-reached" {
                    if value != 0, !reportedEnd { events.append(.ended); reportedEnd = true }
                    if value == 0 { reportedEnd = false }
                } else {
                    events.append(.property(name, value))
                }
            default: continue
            }
        }
        if !events.isEmpty { deliver(events) }
    }

    private func deliver(_ events: [Event]) {
        let generation = generation
        let receive = receive
        Task { @MainActor in receive(generation, events) }
    }
}
