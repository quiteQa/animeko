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
            guard isActive, window != nil, video.superview !== self else { return }
            video.removeFromSuperview()
            video.frame = bounds
            video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(video)
        }
    }
}
