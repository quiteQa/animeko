import XCTest

final class PlayerInteractionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testRepeatedManualExitRestoresInlineLayoutAndTouches() {
        let app = XCUIApplication()
        app.launch()
        for _ in 0..<3 {
            XCTAssertTrue(app.buttons["enter-fullscreen"].waitForExistence(timeout: 5))
            app.buttons["enter-fullscreen"].tap()
            XCTAssertTrue(app.buttons["exit-fullscreen"].waitForExistence(timeout: 5))
            app.buttons["exit-fullscreen"].tap()
            let details = app.staticTexts["details"]
            XCTAssertTrue(details.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["playback"].isHittable)
            app.buttons["playback"].tap()
            XCTAssertEqual(app.buttons["playback"].label, "播放")
            app.buttons["playback"].tap()
            XCTAssertEqual(app.buttons["playback"].label, "暂停")
            app.buttons["sources"].tap()
            XCTAssertTrue(app.staticTexts["source-list"].exists)
            app.buttons["sources"].tap()
            let video = app.otherElements["inline-video"].frame
            XCTAssertEqual(video.width / video.height, 16.0 / 9.0, accuracy: 0.03)
            XCTAssertLessThan(video.maxY, details.frame.minY)
        }
    }

    @MainActor
    func testPhysicalPortraitReturnsToDetailsAndPlaybackRemainsInteractive() {
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["exit-fullscreen"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["details"].waitForExistence(timeout: 5))
        app.buttons["playback"].tap()
        XCTAssertEqual(app.buttons["playback"].label, "播放")
    }

    @MainActor
    func testSideGesturesAndLockPreserveButtonAndSliderTouches() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["enter-fullscreen"].tap()
        XCTAssertTrue(app.buttons["exit-fullscreen"].waitForExistence(timeout: 5))
        let fullscreen = app.otherElements["fullscreen"]
        let left = fullscreen.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.56))
        left.press(forDuration: 0.05, thenDragTo: fullscreen.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.32)))
        XCTAssertEqual(app.staticTexts["indicator"].label, "brightness")
        let right = fullscreen.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.56))
        right.press(forDuration: 0.05, thenDragTo: fullscreen.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.32)))
        XCTAssertEqual(app.staticTexts["indicator"].label, "volume")
        app.sliders["progress"].adjust(toNormalizedSliderPosition: 0.7)
        app.buttons["playback"].tap()
        XCTAssertEqual(app.buttons["playback"].label, "播放")
        app.buttons["lock"].tap()
        XCTAssertEqual(app.buttons["lock"].label, "解锁")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["exit-fullscreen"].exists)
        app.buttons["exit-fullscreen"].tap()
        XCTAssertTrue(app.buttons["sources"].waitForExistence(timeout: 5))
    }
}
