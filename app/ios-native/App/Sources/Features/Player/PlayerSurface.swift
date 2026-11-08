import AVFoundation
import AVKit
import SwiftUI

/// 包装上游的 `EnhancedPlayerView` (AVPlayerLayer + Metal 画质增强). 画质增强默认关闭 (mode 0).
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    /// 画中画控制器创建后回调, 由控件层的画中画按钮使用.
    var onPictureInPictureReady: (AVPictureInPictureController) -> Void = { _ in }

    func makeUIView(context: Context) -> EnhancedPlayerView {
        let view = EnhancedPlayerView(player: player, onUnavailable: {})
        view.update(mode: 0, aspect: 0)
        if AVPictureInPictureController.isPictureInPictureSupported(),
           let layer = view.layer as? AVPlayerLayer,
           let controller = AVPictureInPictureController(playerLayer: layer) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            context.coordinator.pictureInPicture = controller
            // 回调通常会修改 SwiftUI 状态, 不能在视图更新过程中同步执行
            DispatchQueue.main.async { onPictureInPictureReady(controller) }
        }
        return view
    }

    func updateUIView(_ view: EnhancedPlayerView, context: Context) {}

    static func dismantleUIView(_ view: EnhancedPlayerView, coordinator: Coordinator) {
        view.close()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var pictureInPicture: AVPictureInPictureController?
    }
}
