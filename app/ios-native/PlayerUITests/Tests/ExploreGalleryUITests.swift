import XCTest

final class ExploreGalleryUITests: XCTestCase {
    @MainActor
    func testSeasonalHeroOpensSelectedSubjectAndSearchRemainsReachable() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--explore-gallery", "-AppleLanguages", "(zh-Hans)"]
        app.launch()

        let page = app.buttons["explore-page-2"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        page.tap()
        let hero = app.buttons["explore-hero-2"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        hero.tap()
        let detail = app.staticTexts["gallery-detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(detail.label, "薄暮书店")

        let tabs = app.tabBars
        let explore = tabs.buttons["探索"].firstMatch
        let search = tabs.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "搜索", "Search")).firstMatch
        XCTAssertTrue(search.exists)
        search.tap()
        XCTAssertTrue(app.staticTexts["gallery-search"].waitForExistence(timeout: 5))
        explore.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["explore-schedule"].tap()
        XCTAssertTrue(app.staticTexts["gallery-schedule"].waitForExistence(timeout: 5))
    }
}
