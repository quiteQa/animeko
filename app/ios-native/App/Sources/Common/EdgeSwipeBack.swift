import UIKit

/// 从屏幕左边缘向右滑动返回上一页, 包括隐藏了导航栏的页面 (如播放页).
///
/// SwiftUI 隐藏导航栏后系统的返回手势不再生效; 这里由导航控制器自己作为该手势的代理, 只要还有上一页就允许开始.
/// 横屏全屏播放时不响应, 以免播放中误触返回. 其他手势 (如播放页详情 / 评论的左右翻页) 在边缘手势失败后才开始,
/// 所以从边缘开始的滑动总是返回.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === interactivePopGestureRecognizer else { return true }
        if view.window?.windowScene?.effectiveGeometry.interfaceOrientation.isLandscape == true,
           UIDevice.current.userInterfaceIdiom == .phone {
            return false
        }
        return viewControllers.count > 1 && transitionCoordinator == nil
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer,
    ) -> Bool {
        gestureRecognizer === interactivePopGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer
    }
}
