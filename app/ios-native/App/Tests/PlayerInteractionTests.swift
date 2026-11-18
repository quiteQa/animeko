#if canImport(NativePlaybackSupport)
@testable import NativePlaybackSupport
#endif
import Testing

struct PlayerInteractionTests {
    @Test func portraitExitsWithoutAnEarlierLandscapeNotification() {
        var state = PlayerPresentationState()
        state.enterFullscreen()
        state.deviceRotated(to: .portrait, canAutoEnter: true)
        #expect(!state.isFullscreen)
    }

    @Test func manualExitIgnoresStaleLandscapeUntilPhoneIsPortrait() {
        var state = PlayerPresentationState()
        for _ in 0..<50 {
            state.enterFullscreen()
            state.exitFullscreen()
            state.deviceRotated(to: .landscape, canAutoEnter: true)
            #expect(!state.isFullscreen)
            state.deviceRotated(to: .unknown, canAutoEnter: true)
            #expect(!state.isFullscreen)
            state.deviceRotated(to: .portrait, canAutoEnter: true)
            state.deviceRotated(to: .landscape, canAutoEnter: true)
            #expect(state.isFullscreen)
        }
    }

    @Test func lockPreventsRotationButExplicitExitClearsLock() {
        var state = PlayerPresentationState()
        state.enterFullscreen()
        state.isLocked = true
        state.deviceRotated(to: .portrait, canAutoEnter: true)
        #expect(state.isFullscreen)
        state.exitFullscreen()
        #expect(!state.isFullscreen)
        #expect(!state.isLocked)
        state.deviceRotated(to: .portrait, canAutoEnter: false)
        state.deviceRotated(to: .landscape, canAutoEnter: false)
        #expect(!state.isFullscreen)
    }

    @Test func verticalDragKeepsItsStartingSideAndInitialValue() {
        var drag = PlayerVerticalAdjustment()
        let first = drag.update(startX: 100, startY: 180, translationX: 2, translationY: -70,
                                width: 800, height: 400, topInset: 98, bottomInset: 80,
                                brightness: 0.5, volume: 0.8)
        #expect(drag.target == .brightness)
        #expect(first == 0.75)
        let later = drag.update(startX: 100, startY: 180, translationX: 450, translationY: -140,
                                width: 800, height: 400, topInset: 98, bottomInset: 80,
                                brightness: 0.75, volume: 0.8)
        #expect(drag.target == .brightness)
        #expect(later == 1)
    }

    @Test func rightHandVolumeClampsAtBothLimits() {
        for (dy, expected) in [(-500.0, 1.0), (500.0, 0.0)] {
            var drag = PlayerVerticalAdjustment()
            let value = drag.update(startX: 700, startY: 180, translationX: 0, translationY: dy,
                                    width: 800, height: 400, topInset: 98, bottomInset: 80,
                                    brightness: 0.5, volume: 0.5)
            #expect(drag.target == .volume)
            #expect(value == expected)
        }
    }

    @Test func horizontalDragAndControlEdgesNeverAdjustValues() {
        for (x, y, dx, dy) in [(100.0, 20.0, 0.0, 90.0), (700, 370, 0, -90),
                                (4, 180, 0, -90), (100, 180, 80, 20)] {
            var drag = PlayerVerticalAdjustment()
            #expect(drag.update(startX: x, startY: y, translationX: dx, translationY: dy,
                                width: 800, height: 400, topInset: 98, bottomInset: 80,
                                brightness: 0.5, volume: 0.5) == nil)
            #expect(drag.update(startX: x, startY: y, translationX: 0, translationY: -100,
                                width: 800, height: 400, topInset: 98, bottomInset: 80,
                                brightness: 0.5, volume: 0.5) == nil)
        }
    }
}
