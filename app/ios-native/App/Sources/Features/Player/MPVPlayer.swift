import Foundation
import UIKit

/// 播放器的主线程状态. 原生调用由 MPVBackend 的专用队列管理.
@MainActor
final class MPVPlayer {
    let videoView = MPVVideoView()
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPaused = true
    private(set) var isBuffering = false
    private(set) var hasMedia = false
    private(set) var speed: Double = 1
    private(set) var cacheSpeed: Double = 0
    var onChange: (() -> Void)?
    var onReady: (() -> Void)?
    var onEndOfFile: (() -> Void)?
    var onLoadFailed: ((String) -> Void)?

    let pictureInPicture = MPVPictureInPicture()
    private(set) var inspection: MediaInspection?
    private(set) var inspectionComplete = false
    private var inspectionTask: Task<Void, Never>?
    private var pipTimeout: Task<Void, Never>?
    private var frameEpoch = UUID()
    private var seekWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var measurements = PlaybackMeasurements()
    var onPictureInPictureChanged: ((Bool) -> Void)?
    var onRestorePictureInPicture: (() async -> Bool)?
    var onPictureInPictureFailure: ((String) -> Void)?
    var retainsPlayback: Bool { pictureInPicture.active || pictureInPicture.starting }
    var canStartPictureInPicture: Bool {
        hasMedia && inspection?.valid == true && inspection?.isHDR == false
            && [Int32(1), 6, 13].contains(inspection?.transfer ?? 0)
            && [Int32(1), 5, 6].contains(inspection?.primaries ?? 0)
    }
    private var generation = UUID()
    private var isDestroyed = false
    private lazy var backend = MPVBackend(layer: videoView.metalLayer, frames: { [weak self] frame in
        self?.pictureInPicture.enqueue(frame)
    }) { [weak self] generation, events in
        guard let self, !isDestroyed, self.generation == generation else { return }
        apply(events)
    }

    func destroy() {
        guard !isDestroyed else { return }
        inspectionTask?.cancel(); pipTimeout?.cancel(); pictureInPicture.reset()
        finishSeeks()
        isDestroyed = true
        generation = UUID()
        backend.destroy()
    }

    func load(url: String, headers: [String: String], start: Double, autoplay: Bool) {
        guard !isDestroyed else { return }
        stopPictureInPicture()
        inspectionTask?.cancel(); finishSeeks()
        generation = UUID()
        inspection = nil; inspectionComplete = false
        let expected = generation
        inspectionTask = Task { [weak self] in
            let info = try? await MediaInspection.inspect(url: url, headers: headers)
            guard let self, !Task.isCancelled, generation == expected else { return }
            inspection = info; inspectionComplete = true; onChange?()
        }
        measurements.beginLoad(at: ProcessInfo.processInfo.systemUptime)
        position = start.isFinite ? max(0, start) : 0
        duration = 0
        cacheSpeed = 0
        hasMedia = false
        isBuffering = true
        isPaused = !autoplay
        backend.load(url: url, headers: MPVRequestHeaders(headers), start: position, autoplay: autoplay, generation: generation)
        onChange?()
    }

    func stop() {
        guard !isDestroyed else { return }
        stopPictureInPicture(); inspectionTask?.cancel(); finishSeeks()
        generation = UUID()
        measurements.stop()
        backend.stop(generation: generation)
        hasMedia = false
        isPaused = true
        isBuffering = false
        position = 0
        duration = 0
        cacheSpeed = 0
        onChange?()
    }

    func flushCommands() async { await backend.flushCommands() }

    func play() { backend.setString("pause", "no") }
    func pause() { backend.setString("pause", "yes") }

    func seek(to seconds: Double) {
        guard !isDestroyed, seconds.isFinite else { return }
        measurements.beginSeek(at: ProcessInfo.processInfo.systemUptime)
        frameEpoch = UUID()
        pictureInPicture.flush(generation: generation, epoch: frameEpoch)
        backend.invalidateFrames(epoch: frameEpoch)
        backend.seek(to: max(0, duration > 0 ? min(duration, seconds) : seconds))
    }

    func seekAndWait(to seconds: Double) async {
        let id = UUID()
        await withCheckedContinuation { continuation in
            seekWaiters[id] = continuation
            seek(to: seconds)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.seekWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }
    private func finishSeeks() { let waiters = seekWaiters.values; seekWaiters.removeAll(); waiters.forEach { $0.resume() } }
    func startPictureInPicture() {
        guard canStartPictureInPicture else { onPictureInPictureFailure?("此媒体的色彩或格式尚不支持画中画"); return }
        pictureInPicture.setPlaying = { [weak self] in $0 ? self?.play() : self?.pause() }
        pictureInPicture.skip = { [weak self] offset in
            guard let self else { return }; await seekAndWait(to: max(0, min(duration, position + offset)))
        }
        pictureInPicture.restoreUI = { [weak self] in await self?.onRestorePictureInPicture?() ?? false }
        pictureInPicture.onState = { [weak self] active in
            guard let self else { return }
            if !active { stopPictureInPicture() }
            onPictureInPictureChanged?(active)
        }
        pictureInPicture.onFailure = { [weak self] message in self?.stopPictureInPicture(); self?.onPictureInPictureFailure?(message) }
        pictureInPicture.onFirstFrame = { [weak self] in self?.pictureInPicture.view.isHidden = false }
        if pictureInPicture.view.superview == nil {
            pictureInPicture.view.frame = videoView.bounds
            pictureInPicture.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            videoView.addSubview(pictureInPicture.view)
        }
        frameEpoch = UUID()
        pictureInPicture.flush(generation: generation, epoch: frameEpoch)
        pictureInPicture.update(position: position, duration: duration, speed: speed, paused: isPaused)
        pictureInPicture.start()
        backend.setSampleOutput(true, info: inspection, epoch: frameEpoch)
        pipTimeout?.cancel()
        pipTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, pictureInPicture.starting else { return }
            stopPictureInPicture(); onPictureInPictureFailure?("系统画中画未就绪，请返回前台重试")
        }
    }
    func stopPictureInPicture() {
        pipTimeout?.cancel(); pipTimeout = nil
        let wasRetained = retainsPlayback
        pictureInPicture.reset(); pictureInPicture.view.isHidden = true
        if UIApplication.shared.applicationState == .background { backend.setString("vid", "no") }
        backend.setSampleOutput(false, info: nil, epoch: UUID())
        if wasRetained { onPictureInPictureChanged?(false) }
    }
    func addSubtitle(url: String, title: String) { backend.addSubtitle(url: url, title: title) }

    func setSpeed(_ value: Double) {
        guard value.isFinite, value > 0 else { return }
        backend.setString("speed", String(value))
    }

    func setFillsScreen(_ fills: Bool) {
        backend.setString("panscan", fills ? "1" : "0")
        videoView.fillsContainer = fills
    }

    func setEnhancement(_ level: Int) {
        backend.setString("deband", level > 0 ? "yes" : "no")
        backend.setString("scale", level >= 2 ? "ewa_lanczossharp" : "lanczos")
        backend.setString("cscale", level >= 2 ? "ewa_lanczossharp" : "spline36")
    }

    func setVideoEnabled(_ enabled: Bool) { backend.setString("vid", enabled ? "auto" : "no") }
    func screenshot(to url: URL) async -> Bool { await backend.screenshot(to: url) }
    struct Track: Identifiable {
        let id: Int
        let kind: String
        let title: String
        let selected: Bool
    }
    func tracks(kind: String) -> [Track] {
        let count = min(200, max(0, Int(backend.double("track-list/count") ?? 0)))
        return (0..<count).compactMap { index in
            let root = "track-list/\(index)/"
            guard backend.string(root + "type") == kind, let id = backend.double(root + "id") else { return nil }
            let title = [backend.string(root + "title"), backend.string(root + "lang"), backend.string(root + "codec")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return Track(id: Int(id), kind: kind, title: title.isEmpty ? "\(kind == "audio" ? "音轨" : "字幕") \(Int(id))" : title,
                selected: backend.string(root + "selected") == "yes")
        }
    }
    func selectTrack(kind: String, id: Int?) { backend.setString(kind == "audio" ? "aid" : "sid", id.map(String.init) ?? "no") }
    var framePoolDrops: Int { backend.frameState.read().poolDrops }
    func string(_ name: String) -> String? { backend.string(name) }
    func double(_ name: String) -> Double? { backend.double(name) }

    private func apply(_ events: [MPVBackend.Event]) {
        for event in events {
            switch event {
            case .property(let name, let value):
                guard value.isFinite else { continue }
                switch name {
                case "time-pos": position = max(0, value)
                case "duration": duration = max(0, value)
                case "pause": isPaused = value != 0
                case "paused-for-cache": isBuffering = value != 0
                case "speed": speed = value
                case "cache-speed": cacheSpeed = max(0, value)
                default: break
                }
            case .sampleFailure(let message):
                stopPictureInPicture(); onPictureInPictureFailure?(message)
            case .ready:
                measurements.ready(at: ProcessInfo.processInfo.systemUptime)
                finishSeeks()
                hasMedia = true
                isBuffering = false
                onReady?()
            case .ended: onEndOfFile?()
            case .failed(let reason):
                measurements.failed()
                hasMedia = false
                isBuffering = false
                onLoadFailed?(reason)
            }
        }
        pictureInPicture.update(position: position, duration: duration, speed: speed, paused: isPaused || isBuffering)
        onChange?()
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
