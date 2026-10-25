import XCTest

final class BrailioUITests: XCTestCase {
    @MainActor private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchEnvironment["BRAILIO_UI_TEST_RESET"] = "1"; app.launchArguments = arguments; app.launch(); return app
    }
    @MainActor private func choose(_ id: String, in app: XCUIApplication) {
        let target = app.buttons[id]
        XCTAssertTrue(target.waitForExistence(timeout: 4), "Missing fixed control: \(id)")
        target.tap()
        let focus = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "focused"), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [focus], timeout: 3), .completed)
        target.doubleTap()
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testHomeHasNoInstructionsOrScrollingAndTouchDoesNotOpen() {
        let app = launch(); capture(app, "Tactile-Home")
        XCTAssertEqual(app.scrollViews.count, 0)
        XCTAssertFalse(app.switches["touchExploreToggle"].exists)
        XCTAssertFalse(app.staticTexts["Hello, what’s next?"].exists)
        app.buttons["homeWrite"].tap()
        let focus = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "focused"), object: app.buttons["homeWrite"])
        XCTAssertEqual(XCTWaiter.wait(for: [focus], timeout: 3), .completed)
        XCTAssertFalse(app.buttons["dot1"].exists)
        // Double-tap away from the focused Write button; it must still open Write.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).doubleTap()
        XCTAssertTrue(app.otherElements["handwritingCanvas"].waitForExistence(timeout: 4))
    }
    @MainActor func testBrailleWriteDeleteUndoSaveWithoutScrolling() {
        let app = launch(); choose("homeWrite", in: app)
        choose("inkDone", in: app); choose("writeBraille", in: app)
        choose("dot1", in: app)
        XCTAssertTrue((app.buttons["dot1"].value as? String ?? "").contains("On"))
        choose("navNext", in: app); choose("enterCharacter", in: app)
        XCTAssertEqual(app.staticTexts["surfaceStatus"].label, "a")
        choose("navNext", in: app); choose("writeDelete", in: app)
        XCTAssertEqual(app.staticTexts["surfaceStatus"].label, "Write a word")
        choose("writeUndo", in: app)
        XCTAssertEqual(app.staticTexts["surfaceStatus"].label, "a")
        choose("navNext", in: app); choose("writeSave", in: app)
        XCTAssertEqual(app.scrollViews.count, 0)
        choose("navBack", in: app); choose("navNext", in: app); choose("homeNotes", in: app)
        XCTAssertTrue(app.buttons["note0"].exists)
        capture(app, "Tactile-Notes")
    }
    @MainActor func testEveryPrimaryFeatureHasFixedNavigation() {
        let app = launch()
        for id in ["homeRead", "homeTalk", "homeFind", "homeGo", "homeLearn"] {
            choose(id, in: app)
            XCTAssertEqual(app.scrollViews.count, 0, "\(id) requires scrolling")
            for navigation in ["navBack", "navReplay", "navStatus", "navNext"] {
                let frame = app.buttons[navigation].frame
                XCTAssertGreaterThanOrEqual(frame.width, 44)
                XCTAssertGreaterThanOrEqual(frame.height, 44)
                XCTAssertTrue(app.frame.contains(frame))
            }
            capture(app, "Tactile-\(id)")
            choose("navBack", in: app)
        }
    }
    @MainActor func testPagesExposeSettingsAndConversationReply() {
        let app = launch(); choose("navNext", in: app); choose("homeSettings", in: app)
        XCTAssertTrue(app.buttons["settingsTest"].exists)
        choose("navBack", in: app); choose("homeTalk", in: app)
        choose("talkReply", in: app)
        XCTAssertTrue(app.buttons["replyListen"].exists)
        XCTAssertTrue(app.buttons["replyType"].exists)
        XCTAssertEqual(app.scrollViews.count, 0)
    }
    @MainActor func testLargestTextPreservesZonesAndReachability() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        for id in ["homeRead", "homeWrite", "homeTalk", "homeFind", "homeGo", "homeLearn"] {
            XCTAssertTrue(app.frame.contains(app.buttons[id].frame))
            XCTAssertGreaterThanOrEqual(app.buttons[id].frame.height, 44)
        }
        capture(app, "Tactile-Largest-Text")
        choose("homeWrite", in: app)
        choose("inkDone", in: app); choose("writeBraille", in: app)
        let frames = [1,4,2,5,3,6].map { app.buttons["dot\($0)"].frame }
        XCTAssertTrue(frames.allSatisfy { app.frame.contains($0) && $0.height >= 44 })
        choose("dot1", in: app); choose("navNext", in: app)
        XCTAssertTrue(app.buttons["enterCharacter"].isEnabled)
        capture(app, "Tactile-Write-Largest-Text")
    }
    @MainActor func testDarkAppearanceKeepsAllHomeActionsVisible() {
        let app = launch(["-AppleInterfaceStyle", "Dark"])
        XCTAssertEqual(app.scrollViews.count, 0)
        capture(app, "Tactile-Home-Dark")
        choose("homeFind", in: app)
        XCTAssertTrue(app.buttons["roomHoldControl"].exists)
        capture(app, "Tactile-Find-Dark")
    }
    @MainActor func testFingerLiftPreviewsWordAndDeleteClearsInkWithoutScrolling() {
        let app = launch(); choose("homeWrite", in: app)
        let canvas = app.otherElements["handwritingCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 4))
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        let recognized = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "Write a word"), object: app.staticTexts["surfaceStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [recognized], timeout: 12), .completed)
        XCTAssertFalse(app.staticTexts["surfaceStatus"].label.isEmpty)
        XCTAssertEqual(app.scrollViews.count, 0)
        capture(app, "Handwriting-After-Lift")
        choose("inkDelete", in: app)
        XCTAssertEqual(app.staticTexts["surfaceStatus"].label, "Write a word")
    }

    @MainActor func testObjectNameHandwritingReturnsToRoomWorkflow() {
        let app = launch(); choose("homeFind", in: app); choose("navNext", in: app); choose("findWrite", in: app)
        let canvas = app.otherElements["handwritingCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 4))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)), withVelocity: .slow, thenHoldForDuration: 0)
        let recognized = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "Write a word"), object: app.staticTexts["surfaceStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [recognized], timeout: 12), .completed)
        choose("inkDone", in: app)
        XCTAssertTrue(app.buttons["roomHoldControl"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.scrollViews.count, 0)
        capture(app, "Room-After-Written-Query")
    }

    @MainActor func testDocumentLibraryReadsPagesAndResumesWithoutScrolling() {
        let app = XCUIApplication(); app.launchEnvironment["BRAILIO_UI_TEST_RESET"] = "1"; app.launchEnvironment["BRAILIO_UI_TEST_LIBRARY"] = "1"; app.launchArguments = ["-slotDuration", "0.001"]; app.launch()
        choose("homeRead", in: app); choose("readDocuments", in: app); choose("docLibrary", in: app)
        choose("navNext", in: app); choose("library0", in: app)
        XCTAssertTrue(app.staticTexts["readerPosition"].waitForExistence(timeout: 6))
        choose("navNext", in: app); choose("navNext", in: app); choose("bookNext", in: app)
        let pageTwo = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "p2 "), object: app.staticTexts["readerPosition"])
        XCTAssertEqual(XCTWaiter.wait(for: [pageTwo], timeout: 6), .completed)
        XCTAssertEqual(app.scrollViews.count, 0); capture(app, "Document-Page-Two")
        choose("navBack", in: app); choose("navNext", in: app); choose("library0", in: app)
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "p2 "), object: app.staticTexts["readerPosition"])
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 6), .completed)
        choose("navNext", in: app); choose("navNext", in: app); choose("bookPrevious", in: app)
        let firstPage = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "p1 "), object: app.staticTexts["readerPosition"])
        XCTAssertEqual(XCTWaiter.wait(for: [firstPage], timeout: 6), .completed)
        choose("bookReadAll", in: app)
        let automaticPage = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "p2 "), object: app.staticTexts["readerPosition"])
        XCTAssertEqual(XCTWaiter.wait(for: [automaticPage], timeout: 6), .completed)
    }

    @MainActor func testNavigationProviderSelectionUsesFixedPages() {
        let app = launch(); choose("homeGo", in: app); choose("navNext", in: app)
        choose("goGoogle", in: app)
        XCTAssertTrue((app.buttons["goGoogle"].value as? String ?? "").contains("On") || app.buttons["goGoogle"].isSelected)
        XCTAssertTrue(app.buttons["goGoogleOpen"].exists)
        choose("goApple", in: app)
        XCTAssertEqual(app.scrollViews.count, 0); capture(app, "Navigation-Providers")
    }
    @MainActor func testRouteStartExploreResumeAndStopWithoutScrolling() {
        let app = XCUIApplication(); app.launchEnvironment["BRAILIO_UI_TEST_RESET"] = "1"; app.launchEnvironment["BRAILIO_UI_TEST_ROUTE"] = "1"; app.launch()
        choose("homeGo", in: app); choose("goCurrent", in: app)
        XCTAssertTrue(app.staticTexts["routeSummary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["tactileRouteMap"].waitForExistence(timeout:5))
        choose("navNext", in: app); choose("routeStart", in: app)
        XCTAssertEqual(app.buttons["routeStart"].label, "Resume")
        choose("navNext", in: app)
        XCTAssertTrue(app.buttons["routeStop"].exists); choose("routeStop", in: app)
        choose("navNext", in: app); choose("navNext", in: app); choose("navNext", in: app)
        XCTAssertEqual(app.buttons["routeStart"].label, "Start")
        XCTAssertEqual(app.scrollViews.count, 0); capture(app, "Navigation-Route-Controls")
    }

    @MainActor func testWrittenDestinationDoneStartsTactileAppleMap() {
        let app=XCUIApplication(); app.launchEnvironment["BRAILIO_UI_TEST_RESET"]="1";app.launchEnvironment["BRAILIO_UI_TEST_ROUTE"]="1";app.launch()
        choose("homeGo",in:app);choose("goWrite",in:app)
        let canvas=app.otherElements["handwritingCanvas"]
        canvas.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.15)).press(forDuration:0.1,thenDragTo:canvas.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.8)),withVelocity:.slow,thenHoldForDuration:0)
        choose("inkDone",in:app)
        let hasMap=app.otherElements["tactileRouteMap"].waitForExistence(timeout:12)
        if !hasMap { print(app.debugDescription); capture(app,"Auto-route-failed-state") }
        XCTAssertTrue(hasMap)
        XCTAssertTrue(app.staticTexts.matching(identifier:"routeSummary").allElementsBoundByIndex.contains { $0.label.contains("Apple Maps") })
        capture(app,"Tactile-Apple-Map")
        let mapPoint=app.otherElements["tactileRouteMap"].coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5))
        mapPoint.press(forDuration:0.5); mapPoint.doubleTap()
        XCTAssertTrue(app.buttons["routeRead"].waitForExistence(timeout:5))
        XCTAssertEqual(app.buttons["routeStart"].label,"Resume")
        XCTAssertEqual(app.scrollViews.count,0);capture(app,"Automatic-Apple-Tactile-Map")
    }

}
