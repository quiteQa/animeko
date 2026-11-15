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

    private var generation = UUID()
    private var isDestroyed = false
    private lazy var backend = MPVBackend(layer: videoView.metalLayer) { [weak self] generation, events in
        guard let self, !isDestroyed, self.generation == generation else { return }
        apply(events)
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        generation = UUID()
        backend.destroy()
    }

    func load(url: String, headers: [String: String], start: Double, autoplay: Bool) {
        guard !isDestroyed else { return }
        generation = UUID()
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
        generation = UUID()
        backend.stop(generation: generation)
        hasMedia = false
        isPaused = true
        isBuffering = false
        position = 0
        duration = 0
        cacheSpeed = 0
        onChange?()
    }

    func play() { backend.setString("pause", "no") }
    func pause() { backend.setString("pause", "yes") }

    func seek(to seconds: Double) {
        guard !isDestroyed, seconds.isFinite else { return }
        backend.seek(to: max(0, seconds))
    }

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
            case .ready:
                hasMedia = true
                isBuffering = false
                onReady?()
            case .ended: onEndOfFile?()
            case .failed(let reason):
                hasMedia = false
                isBuffering = false
                onLoadFailed?(reason)
            }
        }
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
