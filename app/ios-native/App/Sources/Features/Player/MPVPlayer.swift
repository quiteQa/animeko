import Foundation
import Libmpv
import UIKit

/// libmpv 播放内核. 一个实例对应一个播放页, 连续播放多集时复用.
///
/// 画面经 gpu-next (Vulkan → MoltenVK → Metal) 渲染到 `videoView` 的 `CAMetalLayer`, 硬件解码用 VideoToolbox.
/// libmpv 的事件在后台队列读取, 状态变化在主线程更新并回调 `onChange`.
final class MPVPlayer: @unchecked Sendable {
    /// 承载画面的视图. 同一时刻只能放在一个父视图中, 由 `PlayerSurface` 在内嵌与全屏之间移动.
    let videoView = MPVVideoView()

    // 以下状态只在主线程读写
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPaused = true
    private(set) var isBuffering = false
    private(set) var hasMedia = false
    private(set) var speed: Double = 1
    /// 最近的下载速度 (字节/秒).
    private(set) var cacheSpeed: Double = 0

    /// 状态变化 (主线程).
    var onChange: (() -> Void)?
    /// 播放到结尾 (主线程).
    var onEndOfFile: (() -> Void)?
    /// 加载失败 (主线程), 参数为 mpv 的错误描述.
    var onLoadFailed: ((String) -> Void)?

    private var handle: OpaquePointer?
    /// libmpv 唤醒回调持有的上下文. 只弱引用播放器, 播放器释放后回调不再访问它.
    private var wakeupTarget: Unmanaged<WakeupTarget>?
    private let queue = DispatchQueue(label: "me.him188.ani.native.mpv", qos: .userInitiated)

    private enum Property: UInt64, CaseIterable {
        case timePos = 1, duration, pause, pausedForCache, eofReached, speed, idleActive, cacheSpeed

        var name: String {
            switch self {
            case .timePos: "time-pos"
            case .duration: "duration"
            case .pause: "pause"
            case .pausedForCache: "paused-for-cache"
            case .eofReached: "eof-reached"
            case .speed: "speed"
            case .idleActive: "idle-active"
            case .cacheSpeed: "cache-speed"
            }
        }

        var format: mpv_format {
            switch self {
            case .timePos, .duration, .speed: MPV_FORMAT_DOUBLE
            case .pause, .pausedForCache, .eofReached, .idleActive: MPV_FORMAT_FLAG
            case .cacheSpeed: MPV_FORMAT_INT64
            }
        }
    }

    init() {
        Diagnostics.log("mpv: mpv_create")
        guard let handle = mpv_create() else {
            Diagnostics.log("mpv: mpv_create 返回空")
            return
        }
        self.handle = handle
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(videoView.metalLayer).toOpaque()))
        mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
        for (name, value) in [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            ("video-rotate", "no"),
            // 播完停在最后一帧, 由 eof-reached 通知播放页
            ("keep-open", "yes"),
            ("idle", "yes"),
            ("ytdl", "no"),
            ("input-default-bindings", "no"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "150MiB"),
            ("demuxer-max-back-bytes", "50MiB"),
            ("subs-fallback", "yes"),
            ("terminal", "no"),
            // 不读取配置目录, 不加载内置 Lua 脚本 (osc, stats, console 等): 界面全部由 SwiftUI 提供,
            // 脚本在 iOS 上也无处安放
            ("config", "no"),
            ("load-scripts", "no"),
            ("osc", "no"),
            ("load-stats-overlay", "no"),
            ("load-console", "no"),
            ("load-select", "no"),
            ("load-positioning", "no"),
            ("load-commands", "no"),
            ("load-context-menu", "no"),
            ("load-auto-profiles", "no"),
            ("input-media-keys", "no"),
            ("input-terminal", "no"),
            // mpv 的详细日志直接写文件: 初始化过程中崩溃时, 事件队列里的日志来不及读出
            ("log-file", Diagnostics.mpvLogURL.path),
            ("msg-level", "all=v"),
        ] {
            let status = mpv_set_option_string(handle, name, value)
            if status < 0 {
                Diagnostics.log("mpv: 选项 \(name)=\(value) 失败: \(String(cString: mpv_error_string(status)))")
            }
        }
        // mpv 自己的警告与错误也写入诊断日志
        mpv_request_log_messages(handle, "warn")
        Diagnostics.log("mpv: mpv_initialize")
        let initialized = mpv_initialize(handle)
        Diagnostics.log("mpv: mpv_initialize = \(initialized) \(String(cString: mpv_error_string(initialized)))")
        for property in Property.allCases {
            mpv_observe_property(handle, property.rawValue, property.name, property.format)
        }
        let target = Unmanaged.passRetained(WakeupTarget(self))
        wakeupTarget = target
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            Unmanaged<WakeupTarget>.fromOpaque(context).takeUnretainedValue().player?.drainEvents()
        }, target.toOpaque())
        Diagnostics.log("mpv: 已就绪")
    }

    deinit {
        destroy()
    }

    /// 停止并释放 libmpv. 之后不能再使用.
    func destroy() {
        guard let handle else { return }
        self.handle = nil
        mpv_set_wakeup_callback(handle, nil, nil)
        let target = wakeupTarget
        wakeupTarget = nil
        queue.async {
            mpv_terminate_destroy(handle)
            target?.release()
        }
    }

    private final class WakeupTarget {
        weak var player: MPVPlayer?
        init(_ player: MPVPlayer) { self.player = player }
    }

    // MARK: - 控制

    /// 打开地址. `start` 为起始秒数; `autoplay` 为 `false` 时加载后暂停.
    func load(url: String, headers: [String: String], start: Double, autoplay: Bool) {
        var others: [String] = []
        for (key, value) in headers {
            switch key.lowercased() {
            case "user-agent": setString("user-agent", value)
            case "referer": setString("referrer", value)
            default: others.append("\(key): \(value)")
            }
        }
        setString("http-header-fields", others.joined(separator: ","))
        Diagnostics.log("mpv: loadfile \(URL(string: url)?.host() ?? "?") start=\(Int(start)) headers=\(headers.keys.sorted())")
        var options = ["pause=\(autoplay ? "no" : "yes")"]
        if start > 0 { options.append("start=\(start)") }
        command(["loadfile", url, "replace", "-1", options.joined(separator: ",")])
        hasMedia = true
        position = start
        duration = 0
        isPaused = !autoplay
        onChange?()
    }

    func stop() {
        command(["stop"])
        hasMedia = false
        position = 0
        duration = 0
        onChange?()
    }

    func play() { setFlag("pause", false) }

    func pause() { setFlag("pause", true) }

    func seek(to seconds: Double) {
        command(["seek", String(max(0, seconds)), "absolute"])
        position = max(0, seconds)
        onChange?()
    }

    func setSpeed(_ value: Double) {
        setDouble("speed", value)
    }

    /// `true` 时画面放大填满 (裁切边缘), 否则完整显示.
    func setFillsScreen(_ fills: Bool) {
        setDouble("panscan", fills ? 1 : 0)
        videoView.fillsContainer = fills
    }

    /// 画质增强档位: 0 关闭, 1 性能优先 (去色带), 2 最高质量 (高质量缩放 + 去色带).
    func setEnhancement(_ level: Int) {
        setString("deband", level > 0 ? "yes" : "no")
        let scaler = level >= 2 ? "ewa_lanczossharp" : "lanczos"
        setString("scale", scaler)
        setString("cscale", level >= 2 ? "ewa_lanczossharp" : "spline36")
    }

    /// 关闭或恢复视频轨道. 进入后台时关闭, 只保留声音.
    func setVideoEnabled(_ enabled: Bool) {
        setString("vid", enabled ? "auto" : "no")
    }

    /// 把当前帧保存为 PNG 文件.
    func screenshot(to url: URL) -> Bool {
        guard handle != nil else { return false }
        command(["screenshot-to-file", url.path, "video"])
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 读取字符串属性, 用于播放信息.
    func string(_ name: String) -> String? {
        guard let handle, let value = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    func double(_ name: String) -> Double? {
        guard let handle else { return nil }
        var value = 0.0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    // MARK: - libmpv 调用

    private func command(_ args: [String]) {
        guard let handle else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        mpv_command(handle, &cargs)
    }

    private func setString(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_property_string(handle, name, value)
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let handle else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard let handle else { return }
        var number = value
        mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &number)
    }

    // MARK: - 事件

    private enum Event {
        case property(Property, Double)
        case endFile(failed: String?)
    }

    private func drainEvents() {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            var events: [Event] = []
            while true {
                guard let event = mpv_wait_event(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE else { break }
                switch event.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    guard let property = Property(rawValue: event.reply_userdata),
                          let data = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                          let pointer = data.data else { continue }
                    let value: Double = switch data.format {
                    case MPV_FORMAT_DOUBLE: pointer.assumingMemoryBound(to: Double.self).pointee
                    case MPV_FORMAT_FLAG: Double(pointer.assumingMemoryBound(to: Int32.self).pointee)
                    case MPV_FORMAT_INT64: Double(pointer.assumingMemoryBound(to: Int64.self).pointee)
                    default: 0
                    }
                    events.append(.property(property, value))
                case MPV_EVENT_LOG_MESSAGE:
                    if let message = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
                        let prefix = message.prefix.map { String(cString: $0) } ?? "?"
                        let text = message.text.map { String(cString: $0) } ?? ""
                        Diagnostics.log("mpv[\(prefix)] \(text.trimmingCharacters(in: .newlines))")
                    }
                    continue
                case MPV_EVENT_END_FILE:
                    guard let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee else { continue }
                    if end.reason == MPV_END_FILE_REASON_ERROR {
                        events.append(.endFile(failed: String(cString: mpv_error_string(end.error))))
                    }
                default:
                    continue
                }
            }
            guard !events.isEmpty else { return }
            DispatchQueue.main.async { self.apply(events) }
        }
    }

    private func apply(_ events: [Event]) {
        var reachedEnd = false
        for event in events {
            switch event {
            case .property(let property, let value):
                switch property {
                case .timePos: position = value
                case .duration: duration = value
                case .pause: isPaused = value != 0
                case .pausedForCache: isBuffering = value != 0
                case .eofReached: reachedEnd = reachedEnd || value != 0
                case .speed: speed = value
                case .idleActive: if value != 0 { hasMedia = false }
                case .cacheSpeed: cacheSpeed = value
                }
            case .endFile(let failed):
                hasMedia = false
                if let failed { onLoadFailed?(failed) }
            }
        }
        onChange?()
        if reachedEnd { onEndOfFile?() }
    }
}

/// 承载 mpv 画面的视图, 其图层就是 mpv 渲染的 `CAMetalLayer`.
///
/// 视图大小固定为 `canvasSize`, 由所在的容器用缩放变换放进自己的大小 (见 `PlayerSurface`).
/// MPVKit 的 moltenvk 输出只在 mpv 重新配置视频输出时读取图层大小, 重新配置会清掉当前画面;
/// 图层大小不变, 内嵌与全屏切换, 旋转时都不需要 mpv 重新配置, 画面不会闪黑, 缩放随旋转动画平滑进行.
final class MPVVideoView: UIView {
    /// 画布大小 (点). 16:9, 宽度不小于 iPhone 横屏宽度, 全屏时按屏幕像素清晰显示.
    static let canvasSize = CGSize(width: 960, height: 540)

    override class var layerClass: AnyClass { MPVMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// 为 `true` 时容器按填满缩放 (裁切超出部分), 否则完整显示.
    var fillsContainer = false {
        didSet {
            guard fillsContainer != oldValue else { return }
            superview?.setNeedsLayout()
        }
    }

    init() {
        super.init(frame: CGRect(origin: .zero, size: Self.canvasSize))
        backgroundColor = .black
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        isUserInteractionEnabled = false
        updateDrawableSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else { return }
        metalLayer.contentsScale = window.screen.nativeScale
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = metalLayer.contentsScale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }
}

/// MoltenVK 会把 drawableSize 临时设为 1×1 强制完成呈现, 导致闪烁; 忽略这种尺寸
/// (与 MPVKit 示例相同, 见 mpv-player/mpv#13651).
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1, Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}
