import UIKit
import XCTest
@testable import NativeMediaHost

@MainActor
final class PlayerSystemControlsTests: XCTestCase {
    func testBrightnessRestoresAfterVolumeBridgeLosesItsWindow() {
        let screen = TestBrightnessScreen()
        let original = screen.brightness
        defer { screen.brightness = original }
        let controls = PlayerSystemControls()
        controls.screen = screen
        controls.adjust(.brightness, to: original > 0.5 ? 0.25 : 0.75)
        XCTAssertNotEqual(screen.brightness, original)
        // 窗口拆除后桥接器不持有屏幕; 恢复使用调节开始时保存的屏幕和亮度.
        controls.screen = nil
        controls.restoreBrightness()
        XCTAssertEqual(screen.brightness, original, accuracy: 0.001)
        screen.brightness = 0.4
        controls.restoreBrightness()
        XCTAssertEqual(screen.brightness, 0.4, accuracy: 0.001)
    }

    func testVolumeUsesSliderEventsAndRejectsDisabledOutputs() {
        let controls = PlayerSystemControls()
        let slider = UISlider()
        slider.minimumValue = 0; slider.maximumValue = 1
        let receiver = SliderReceiver()
        slider.addTarget(receiver, action: #selector(SliderReceiver.changed), for: .valueChanged)
        controls.volumeSlider = slider
        controls.adjust(.volume, to: 0.7)
        XCTAssertEqual(slider.value, 0.7, accuracy: 0.001)
        XCTAssertEqual(receiver.events, 1)
        slider.isEnabled = false
        controls.adjust(.volume, to: 0.2)
        XCTAssertEqual(slider.value, 0.7, accuracy: 0.001)
        XCTAssertEqual(receiver.events, 1)
        XCTAssertEqual(controls.indicator?.unavailable, true)
    }
}

@MainActor
private final class TestBrightnessScreen: PlayerBrightnessScreen {
    var brightness: CGFloat = 0.6
}

@MainActor
private final class SliderReceiver: NSObject {
    var events = 0
    @objc func changed() { events += 1 }
}
