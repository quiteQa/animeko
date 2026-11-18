import Foundation

/// 一次拖动只调节起始侧的一个数值; 横向拖动与控件边缘区域不参与亮度/音量调节.
struct PlayerVerticalAdjustment {
    enum Target { case brightness, volume }
    private(set) var target: Target?
    private var initialValue = 0.0
    private var rejected = false

    mutating func update(
        startX: Double, startY: Double, translationX: Double, translationY: Double,
        width: Double, height: Double, topInset: Double, bottomInset: Double,
        brightness: Double, volume: Double
    ) -> Double? {
        guard !rejected, width.isFinite, height.isFinite, width > 32, height > topInset + bottomInset,
              translationX.isFinite, translationY.isFinite else { return nil }
        if target == nil {
            guard startX >= 16, startX <= width - 16, startY >= topInset, startY <= height - bottomInset else {
                rejected = true
                return nil
            }
            guard max(abs(translationX), abs(translationY)) >= 12 else { return nil }
            guard abs(translationY) > abs(translationX) * 1.25 else {
                rejected = true
                return nil
            }
            target = startX < width / 2 ? .brightness : .volume
            initialValue = target == .brightness ? brightness : volume
        }
        guard initialValue.isFinite else { return nil }
        return min(1, max(0, initialValue - translationY / max(140, height * 0.7)))
    }
}
