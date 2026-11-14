import SwiftUI
import UIKit

/// 显示 mpv 画面. 画面视图只有一个, 同一时刻只由 `isActive` 为 `true` 的 `PlayerSurface` 持有:
/// 全屏时全屏的这个持有, 内嵌的让出; 退出全屏后内嵌的取回. 全屏画面淡出期间 `isActive` 已为 `false`,
/// 不会把画面抢回即将移除的视图.
struct PlayerSurface: UIViewRepresentable {
    let player: MPVPlayer
    /// 为 `false` 时不持有画面 (被全屏覆盖, 或全屏画面正在退出).
    var isActive = true

    func makeUIView(context: Context) -> SurfaceContainer {
        let container = SurfaceContainer(video: player.videoView)
        container.backgroundColor = .black
        container.isActive = isActive
        return container
    }

    func updateUIView(_ container: SurfaceContainer, context: Context) {
        container.isActive = isActive
    }

    final class SurfaceContainer: UIView {
        private let video: UIView

        /// 持有画面时, 进入窗口或重新布局都会确认画面在自己之内; 画面被另一个容器取走后, 取回由下一次布局完成.
        var isActive = false {
            didSet { if isActive { attachIfNeeded() } }
        }

        init(video: UIView) {
            self.video = video
            super.init(frame: .zero)
            clipsToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attachIfNeeded()
        }

        private func attachIfNeeded() {
            guard isActive, window != nil else { return }
            if video.superview !== self {
                video.removeFromSuperview()
                addSubview(video)
            }
            fitVideo()
        }

        /// 画面视图大小固定, 按容器大小缩放后居中: 完整显示时取较小的缩放比例, 填满时取较大的.
        private func fitVideo() {
            let canvas = MPVVideoView.canvasSize
            guard bounds.width > 0, bounds.height > 0 else { return }
            let widthRatio = bounds.width / canvas.width
            let heightRatio = bounds.height / canvas.height
            let fills = (video as? MPVVideoView)?.fillsContainer == true
            let scale = fills ? max(widthRatio, heightRatio) : min(widthRatio, heightRatio)
            video.bounds = CGRect(origin: .zero, size: canvas)
            video.center = CGPoint(x: bounds.midX, y: bounds.midY)
            video.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
    }
}
