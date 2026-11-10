import SwiftUI
import UIKit

/// 显示 mpv 画面. 画面视图只有一个, 由处于活动状态的 `PlayerSurface` 持有:
/// 全屏覆盖内嵌画面时, 全屏的这个活动, 内嵌的让出视图; 退出全屏后再取回.
struct PlayerSurface: UIViewRepresentable {
    let player: MPVPlayer
    /// 为 `false` 时不持有画面 (被全屏覆盖).
    var isActive = true

    func makeUIView(context: Context) -> SurfaceContainer {
        let container = SurfaceContainer()
        container.backgroundColor = .black
        if isActive { container.attach(player.videoView) }
        return container
    }

    func updateUIView(_ container: SurfaceContainer, context: Context) {
        if isActive, player.videoView.superview !== container {
            container.attach(player.videoView)
        }
    }

    final class SurfaceContainer: UIView {
        func attach(_ video: UIView) {
            video.removeFromSuperview()
            video.frame = bounds
            video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(video)
        }
    }
}
