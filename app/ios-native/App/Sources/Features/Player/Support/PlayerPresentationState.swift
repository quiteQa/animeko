/// 播放页独占全屏布局与锁定状态; 手动退出后需重新竖持手机才允许自动进入横屏.
struct PlayerPresentationState {
    enum Orientation { case portrait, landscape, unknown }
    private(set) var isFullscreen = false
    var isLocked = false
    private var waitsForPortrait = false

    mutating func enterFullscreen() {
        isFullscreen = true
        isLocked = false
        waitsForPortrait = false
    }

    mutating func exitFullscreen() {
        isFullscreen = false
        isLocked = false
        waitsForPortrait = true
    }

    mutating func deviceRotated(to orientation: Orientation, canAutoEnter: Bool) {
        guard !isLocked else { return }
        switch orientation {
        case .portrait:
            waitsForPortrait = false
            isFullscreen = false
        case .landscape:
            if canAutoEnter, !waitsForPortrait { isFullscreen = true }
        case .unknown:
            break
        }
    }
}
