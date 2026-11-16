import SwiftUI
import UIKit

/// 应用支持的界面方向由 `OrientationLock.mask` 决定: iPhone 平时竖屏, 全屏播放时横屏; iPad 不限制.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?,
    ) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

@MainActor
enum OrientationLock {
    private static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    fileprivate(set) static var mask: UIInterfaceOrientationMask =
        UIDevice.current.userInterfaceIdiom == .phone ? .portrait : .all

    /// 进入全屏播放: 横屏, 并跟随设备在左右横屏间切换.
    static func enterLandscape() {
        guard isPhone else { return }
        apply(.landscape)
    }

    /// 退出全屏播放: 回到竖屏.
    static func restorePortrait() {
        guard isPhone else { return }
        apply(.portrait)
    }

    private static func apply(_ newMask: UIInterfaceOrientationMask) {
        mask = newMask
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for window in scene.windows {
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask)) { _ in }
        }
    }
}
