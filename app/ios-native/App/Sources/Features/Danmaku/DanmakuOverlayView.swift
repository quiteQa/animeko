import AniCore
import QuartzCore
import SwiftUI
import UIKit

/// 在播放画面上方渲染弹幕. 每条弹幕是一个 `CATextLayer`, 位置在 `CADisplayLink` 回调里按播放器时间计算,
/// 因此暂停, 倍速与跳转都自动跟随播放器, 不需要单独维护动画状态.
final class DanmakuOverlayView: UIView {
    /// 当前播放时间 (秒). 没有媒体时返回 `nil`.
    var currentTime: () -> TimeInterval? = { nil }

    var isDanmakuEnabled = true {
        didSet {
            guard oldValue != isDanmakuEnabled else { return }
            clearActive()
            isHidden = !isDanmakuEnabled
        }
    }

    private struct Active {
        let layer: CATextLayer
        let location: AniDanmakuLocation
        let start: TimeInterval
        let width: CGFloat
        let track: Int
        let speed: CGFloat
    }

    private static let fontSize: CGFloat = 20
    private static let lineHeight: CGFloat = 28
    private static let maxActive = 200
    /// 超过这个时长仍未发出的弹幕直接跳过, 避免跳转后一次性涌出.
    private static let lateTolerance: TimeInterval = 1

    private var items: [AniDanmaku] = []
    private var cursor = 0
    private var active: [Active] = []
    private var reusable: [CATextLayer] = []
    private var allocator = DanmakuTrackAllocator(config: .init(floatingTrackCount: 0, fixedTrackCount: 0, viewportWidth: 0))
    private var lastTime: TimeInterval?
    private var displayLink: CADisplayLink?
    private let font = UIFont.systemFont(ofSize: DanmakuOverlayView.fontSize, weight: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setDanmaku(_ list: [AniDanmaku]) {
        items = list
        clearActive()
        lastTime = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let floatingTracks = max(Int(bounds.height * 0.5 / Self.lineHeight), 1)
        let fixedTracks = max(Int(bounds.height * 0.25 / Self.lineHeight), 1)
        if allocator.config.viewportWidth != bounds.width || allocator.config.floatingTrackCount != floatingTracks {
            allocator = DanmakuTrackAllocator(config: .init(
                floatingTrackCount: floatingTracks,
                fixedTrackCount: fixedTracks,
                viewportWidth: bounds.width,
            ))
            clearActive()
        }
    }

    @objc private func tick() {
        guard isDanmakuEnabled, let time = currentTime(), bounds.width > 0 else { return }
        if let last = lastTime, time < last - 0.05 || time > last + 1.5 {
            // 跳转: 从新位置重新开始
            clearActive()
        }
        if lastTime == nil {
            cursor = firstIndex(atOrAfter: time - Self.lateTolerance)
        }
        lastTime = time

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emit(upTo: time)
        layoutActive(at: time)
        CATransaction.commit()
    }

    private func emit(upTo time: TimeInterval) {
        while cursor < items.count {
            let item = items[cursor]
            let itemTime = TimeInterval(item.timeMillis) / 1000
            guard itemTime <= time else { break }
            cursor += 1
            guard time - itemTime <= Self.lateTolerance, active.count < Self.maxActive else { continue }
            show(item, start: itemTime)
        }
    }

    private func show(_ item: AniDanmaku, start: TimeInterval) {
        let attributed = NSAttributedString(
            string: item.text,
            attributes: [.font: font, .foregroundColor: UIColor(rgb: item.color)],
        )
        let width = ceil(attributed.size().width)
        let track: Int?
        switch item.location {
        case .top: track = allocator.allocateFixed(isTop: true, at: start)
        case .bottom: track = allocator.allocateFixed(isTop: false, at: start)
        default: track = allocator.allocateFloating(width: width, at: start)
        }
        guard let track else { return }

        let layer = reusable.popLast() ?? makeLayer()
        layer.string = attributed
        layer.frame = CGRect(x: bounds.width, y: 0, width: width, height: Self.lineHeight)
        self.layer.addSublayer(layer)
        active.append(Active(
            layer: layer,
            location: item.location,
            start: start,
            width: width,
            track: track,
            speed: allocator.speed(forWidth: width),
        ))
    }

    private func layoutActive(at time: TimeInterval) {
        let fixedDuration = allocator.config.fixedDuration
        active.removeAll { entry in
            let elapsed = time - entry.start
            let origin: CGPoint
            switch entry.location {
            case .top:
                guard elapsed < fixedDuration else { recycle(entry.layer); return true }
                origin = CGPoint(x: (bounds.width - entry.width) / 2, y: CGFloat(entry.track) * Self.lineHeight)
            case .bottom:
                guard elapsed < fixedDuration else { recycle(entry.layer); return true }
                origin = CGPoint(
                    x: (bounds.width - entry.width) / 2,
                    y: bounds.height - CGFloat(entry.track + 1) * Self.lineHeight,
                )
            default:
                let x = bounds.width - CGFloat(elapsed) * entry.speed
                guard x + entry.width > 0 else { recycle(entry.layer); return true }
                origin = CGPoint(x: x, y: CGFloat(entry.track) * Self.lineHeight)
            }
            entry.layer.frame.origin = origin
            return false
        }
    }

    private func makeLayer() -> CATextLayer {
        let layer = CATextLayer()
        layer.contentsScale = traitCollection.displayScale
        layer.alignmentMode = .left
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.9
        layer.shadowRadius = 1
        layer.shadowOffset = .zero
        return layer
    }

    private func recycle(_ layer: CATextLayer) {
        layer.removeFromSuperlayer()
        reusable.append(layer)
    }

    private func clearActive() {
        active.forEach { recycle($0.layer) }
        active.removeAll()
        allocator.reset()
        cursor = 0
        lastTime = nil
    }

    private func firstIndex(atOrAfter time: TimeInterval) -> Int {
        let target = Int64(max(time, 0) * 1000)
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].timeMillis < target { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

private extension UIColor {
    convenience init(rgb: Int32) {
        let value = Int(rgb) & 0xFFFFFF
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1,
        )
    }
}

struct DanmakuOverlay: UIViewRepresentable {
    let danmaku: [AniDanmaku]
    let isEnabled: Bool
    let currentTime: () -> TimeInterval?

    func makeUIView(context: Context) -> DanmakuOverlayView {
        let view = DanmakuOverlayView()
        view.currentTime = currentTime
        view.setDanmaku(danmaku)
        context.coordinator.count = danmaku.count
        return view
    }

    func updateUIView(_ view: DanmakuOverlayView, context: Context) {
        view.currentTime = currentTime
        view.isDanmakuEnabled = isEnabled
        if context.coordinator.count != danmaku.count {
            context.coordinator.count = danmaku.count
            view.setDanmaku(danmaku)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var count = 0
    }
}
