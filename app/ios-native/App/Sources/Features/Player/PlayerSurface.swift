import AVFoundation
import AVKit
import SwiftUI

/// 包装上游的 `EnhancedPlayerView` (AVPlayerLayer + Metal 画质增强), 画质增强档位由 [enhancementMode] 决定.
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var enhancementMode: VideoEnhancementMode = .off
    /// 画面填充屏幕 (裁切边缘); 为 `false` 时完整显示画面.
    var fillsScreen = false
    /// 当前视频无法增强 (如 HDR 或设备不支持) 时回调; 画面已回到原生渲染.
    var onEnhancementUnavailable: () -> Void = {}
    /// 画中画控制器创建后回调, 由控件层的画中画按钮使用.
    var onPictureInPictureReady: (AVPictureInPictureController) -> Void = { _ in }

    func makeUIView(context: Context) -> EnhancedPlayerView {
        let coordinator = context.coordinator
        coordinator.onEnhancementUnavailable = onEnhancementUnavailable
        let view = EnhancedPlayerView(player: player, onUnavailable: { [weak coordinator] in
            coordinator?.onEnhancementUnavailable()
        })
        view.update(mode: enhancementMode.rawValue, aspect: fillsScreen ? 2 : 0)
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

    func updateUIView(_ view: EnhancedPlayerView, context: Context) {
        context.coordinator.onEnhancementUnavailable = onEnhancementUnavailable
        view.update(mode: enhancementMode.rawValue, aspect: fillsScreen ? 2 : 0)
    }

    static func dismantleUIView(_ view: EnhancedPlayerView, coordinator: Coordinator) {
        view.close()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var pictureInPicture: AVPictureInPictureController?
        var onEnhancementUnavailable: () -> Void = {}
    }
}
