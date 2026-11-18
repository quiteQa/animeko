import SwiftUI

/// 两种布局使用相同的可用窗口尺寸; 隐藏的内嵌页不接收触摸, 全屏退出同步交还画面与交互.
struct PlayerViewport<Inline: View, Fullscreen: View>: View {
    let isFullscreen: Bool
    var onPortraitLayout: () -> Void = {}
    @ViewBuilder var inline: () -> Inline
    @ViewBuilder var fullscreen: () -> Fullscreen

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                inline()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(isFullscreen ? 0 : 1)
                    .allowsHitTesting(!isFullscreen)
                    .accessibilityHidden(isFullscreen)
                if isFullscreen {
                    fullscreen()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .zIndex(1)
                }
            }
            .onChange(of: geometry.size) { previous, current in
                if previous.width > previous.height, current.height > current.width {
                    onPortraitLayout()
                }
            }
        }
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
    }
}
