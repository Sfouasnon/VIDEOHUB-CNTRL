import XCTest

final class VideohubOnSetUITests: XCTestCase {
    private var app: XCUIApplication!
    private var mockServer: Process?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let mockServer, mockServer.isRunning {
            mockServer.terminate()
            mockServer.waitUntilExit()
        }
        mockServer = nil
        app = nil
    }

    func testRoutingFiltersSearchKeyboardConfirmationAndScreenshots() throws {
        let session = "routing-\(UUID().uuidString)"
        launchDemo(session: session, count: 40, width: 1_100, height: 700)

        let window = app.windows.firstMatch
        XCTAssertGreaterThanOrEqual(window.frame.width, 1_095)
        XCTAssertGreaterThanOrEqual(window.frame.height, 695)
        capture("minimum-1100x700-top")

        let take = app.buttons["take-route-button"]
        let clear = app.buttons["clear-selection-button"]
        XCTAssertTrue(take.waitForExistence(timeout: 5))
        XCTAssertTrue(clear.waitForExistence(timeout: 5))

        if clear.isEnabled { clear.click() }
        XCTAssertFalse(take.isEnabled)

        // Output 1 initially carries Input 1. Deliberately choose Input 2 so
        // the test proves a route actually changed, rather than merely seeing
        // a confirmation for an already-existing route.
        let source = app.buttons["source-tile-1"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.click()

        let destination = app.buttons["destination-tile-0"]
        scrollUntilHittable(destination, direction: .down)
        destination.click()
        XCTAssertTrue(take.isEnabled)
        capture("minimum-1100x700-destinations")

        take.click()
        XCTAssertTrue(app.staticTexts["Route confirmed"].waitForExistence(timeout: 3))
        XCTAssertTrue(destination.label.contains("Input 2"))

        app.typeKey("f", modifierFlags: .command)
        app.typeText("Output 40")
        let destinationSearch = app.textFields["destination-search-field"]
        XCTAssertEqual(destinationSearch.value as? String, "Output 40")
        XCTAssertTrue(app.buttons["clear-destination-search-button"].waitForExistence(timeout: 2))
        app.buttons["clear-destination-search-button"].click()
        XCTAssertEqual(destinationSearch.value as? String, "")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(take.isEnabled)

        scrollToTop()
        source.click()
        app.typeKey("f", modifierFlags: .command)
        app.typeText("Input 40")
        let sourceSearch = app.textFields["source-search-field"]
        XCTAssertEqual(sourceSearch.value as? String, "Input 40")
        XCTAssertTrue(app.buttons["clear-source-search-button"].waitForExistence(timeout: 2))
        app.buttons["clear-source-search-button"].click()
        XCTAssertEqual(sourceSearch.value as? String, "")

        for filter in ["all", "cameras", "playback", "graphics", "utility", "village", "returns"] {
            let button = app.buttons["source-filter-\(filter)"]
            XCTAssertTrue(button.exists, "Missing filter button: \(filter)")
            button.click()
            XCTAssertTrue(button.isSelected, "Filter did not select: \(filter)")
        }
        app.buttons["source-filter-all"].click()

        clear.click()
        source.click()
        scrollUntilHittable(destination, direction: .down)
        destination.click()
        waitForAbsence(app.staticTexts["Route confirmed"], timeout: 5)
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Route confirmed"].waitForExistence(timeout: 3))

        setConfirmBeforeTake(true)
        scrollToTop()
        clear.click()
        source.click()
        scrollUntilHittable(destination, direction: .down)
        destination.click()
        take.click()
        let cancelConfirmation = app.buttons["cancel-take-button"]
        XCTAssertTrue(cancelConfirmation.waitForExistence(timeout: 3))
        cancelConfirmation.click()
        XCTAssertFalse(cancelConfirmation.exists)
        XCTAssertTrue(take.isEnabled)

        waitForAbsence(app.staticTexts["Route confirmed"], timeout: 5)
        take.click()
        let confirm = app.buttons["confirm-take-button"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.click()
        XCTAssertTrue(app.staticTexts["Route confirmed"].waitForExistence(timeout: 3))
        setConfirmBeforeTake(false)
    }

    func testAllCustomizationChoicesNamingResetPersistenceAndRouteBadgeColor() throws {
        let session = "customization-\(UUID().uuidString)"
        launchDemo(session: session, count: 16, width: 1_600, height: 900)

        let source = app.buttons["source-tile-0"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        openCustomization(for: source)
        replaceText(app.textFields["customization-display-name-field"], with: "Cancelled Name")
        app.buttons["customization-color-pink"].click()
        app.buttons["customization-cancel-button"].click()
        XCTAssertFalse(app.textFields["customization-display-name-field"].exists)
        XCTAssertTrue(source.label.contains("Input 1"))
        XCTAssertTrue((source.value as? String)?.contains("Color Blue") == true)

        openCustomization(for: source)
        replaceText(app.textFields["customization-display-name-field"], with: "QA Input")
        replaceText(app.textFields["customization-group-field"], with: "QA Cameras")

        for color in ["blue", "cyan", "green", "yellow", "orange", "red", "purple", "pink"] {
            let button = app.buttons["customization-color-\(color)"]
            XCTAssertTrue(button.exists, "Missing color choice: \(color)")
            button.click()
            XCTAssertTrue(button.isSelected, "Color did not select: \(color)")
        }
        app.buttons["customization-color-purple"].click()

        for icon in ["camera", "monitor", "playback", "multiview", "router", "return", "record", "graphics", "genericVideo"] {
            let button = app.buttons["customization-icon-\(icon)"]
            XCTAssertTrue(button.exists, "Missing icon choice: \(icon)")
            button.click()
            XCTAssertTrue(button.isSelected, "Icon did not select: \(icon)")
        }
        app.buttons["customization-icon-camera"].click()
        app.buttons["customization-save-button"].click()

        XCTAssertTrue(source.label.contains("QA Input"))
        XCTAssertTrue((source.value as? String)?.contains("Icon Camera") == true)
        XCTAssertTrue((source.value as? String)?.contains("Color Purple") == true)
        XCTAssertTrue((source.value as? String)?.contains("Group QA Cameras") == true)
        capture("wide-1600x900-customized-source")

        app.terminate()
        launchDemo(session: session, count: 16, width: 1_600, height: 900)
        let persistedSource = app.buttons["source-tile-0"]
        XCTAssertTrue(persistedSource.waitForExistence(timeout: 5))
        XCTAssertTrue(persistedSource.label.contains("QA Input"))
        XCTAssertTrue((persistedSource.value as? String)?.contains("Color Purple") == true)

        let destination = app.buttons["destination-tile-0"]
        scrollUntilHittable(destination, direction: .down)
        XCTAssertTrue((destination.value as? String)?.contains("Source color Purple") == true)
        openCustomization(for: destination)
        replaceText(app.textFields["customization-display-name-field"], with: "QA Output")
        replaceText(app.textFields["customization-group-field"], with: "QA Village")
        app.buttons["customization-color-cyan"].click()
        app.buttons["customization-icon-monitor"].click()
        app.buttons["customization-save-button"].click()
        XCTAssertTrue(destination.label.contains("QA Output"))
        XCTAssertTrue((destination.value as? String)?.contains("Icon Monitor") == true)
        XCTAssertTrue((destination.value as? String)?.contains("Color Cyan") == true)
        XCTAssertTrue((destination.value as? String)?.contains("Source color Purple") == true)
        capture("wide-1600x900-customized-destination-and-source-badge")

        openCustomization(for: destination)
        app.buttons["customization-reset-label-button"].click()
        replaceText(app.textFields["customization-group-field"], with: "")
        app.buttons["customization-color-blue"].click()
        app.buttons["customization-icon-genericVideo"].click()
        app.buttons["customization-save-button"].click()
        XCTAssertTrue(destination.label.contains("Output 1"))

        scrollToTop()
        openCustomization(for: persistedSource)
        app.buttons["customization-reset-label-button"].click()
        replaceText(app.textFields["customization-group-field"], with: "")
        app.buttons["customization-color-blue"].click()
        app.buttons["customization-icon-genericVideo"].click()
        app.buttons["customization-save-button"].click()
        XCTAssertTrue(persistedSource.label.contains("Input 1"))
    }

    func testConnectionDisconnectReconnectSettingsAndLiveNames() throws {
        let port = try startMockServer(size: 16)
        let session = "connection-\(UUID().uuidString)"
        launch(
            arguments: [
                "--qa-session", session,
                "--host", "127.0.0.1",
                "--port", String(port),
                "--window-size", "1360", "860"
            ]
        )

        let status = app.staticTexts["connection-status"]
        waitForLabel("Connected", on: status, timeout: 10)
        XCTAssertTrue(app.buttons["source-tile-0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["source-tile-0"].label.contains("Input 1"))

        let connection = app.buttons["connection-button"]
        XCTAssertEqual(connection.label, "Disconnect")
        connection.click()
        waitForLabel("Offline", on: status, timeout: 5)
        XCTAssertTrue(app.textFields["router-host-field"].isEnabled)
        replaceText(app.textFields["router-host-field"], with: " 127.0.0.1 ")
        XCTAssertEqual(connection.label, "Connect")
        connection.click()
        waitForLabel("Connected", on: status, timeout: 10)
        XCTAssertEqual(app.textFields["router-host-field"].value as? String, "127.0.0.1")

        app.typeKey(",", modifierFlags: .command)
        let settingsHost = app.textFields["settings-host-field"]
        XCTAssertTrue(settingsHost.waitForExistence(timeout: 5))
        XCTAssertFalse(settingsHost.isEnabled)
        let reconnect = app.switches["settings-reconnect-toggle"]
        let confirm = app.switches["settings-confirm-toggle"]
        XCTAssertTrue(reconnect.exists)
        XCTAssertTrue(confirm.exists)
        toggle(reconnect)
        toggle(reconnect)
        toggle(confirm)
        toggle(confirm)
        app.typeKey("w", modifierFlags: .command)

        let source = app.buttons["source-tile-0"]
        XCTAssertTrue(source.waitForExistence(timeout: 3))
        source.click()

        let lockedDestination = app.buttons["destination-tile-5"]
        scrollUntilHittable(lockedDestination, direction: .down)
        lockedDestination.click()
        XCTAssertFalse(app.buttons["take-route-button"].isEnabled)
        XCTAssertTrue(app.staticTexts["Output locked by another controller"].waitForExistence(timeout: 2))

        let routableDestination = app.buttons["destination-tile-1"]
        scrollUntilHittable(routableDestination, direction: .up)
        routableDestination.click()
        XCTAssertTrue(app.buttons["take-route-button"].isEnabled)
        app.buttons["take-route-button"].click()
        XCTAssertTrue(app.staticTexts["Route confirmed"].waitForExistence(timeout: 5))
        XCTAssertTrue(routableDestination.label.contains("Input 1"))
        capture("live-1360x860-connected")
    }

    func testResponsiveWindowMatrixTopAndBottom() throws {
        let cases: [(Int, Int, String)] = [
            (1_100, 700, "minimum"),
            (1_360, 860, "default"),
            (1_600, 900, "wide")
        ]

        for (width, height, name) in cases {
            launchDemo(
                session: "matrix-\(name)-\(UUID().uuidString)",
                count: 40,
                width: width,
                height: height
            )
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(window.frame.width, CGFloat(width - 5))
            XCTAssertGreaterThanOrEqual(window.frame.height, CGFloat(height - 5))
            XCTAssertTrue(app.buttons["take-route-button"].isHittable)
            XCTAssertTrue(app.buttons["connection-button"].isHittable)
            XCTAssertTrue(app.buttons["source-tile-0"].isHittable)
            capture("matrix-\(name)-top")

            let destination = app.buttons["destination-tile-39"]
            scrollUntilHittable(destination, direction: .down)
            XCTAssertTrue(destination.isHittable)
            XCTAssertTrue(app.buttons["take-route-button"].isHittable)
            capture("matrix-\(name)-bottom")
            app.terminate()
        }
    }

    private enum ScrollDirection { case up, down }

    private func launchDemo(session: String, count: Int, width: Int, height: Int) {
        launch(
            arguments: [
                "--qa-session", session,
                "--demo-size", String(count),
                "--window-size", String(width), String(height)
            ]
        )
    }

    private func launch(arguments: [String]) {
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func scrollUntilHittable(
        _ element: XCUIElement,
        direction: ScrollDirection,
        attempts: Int = 20
    ) {
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 3))
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return }
            switch direction {
            case .down: scrollView.swipeUp()
            case .up: scrollView.swipeDown()
            }
        }
        XCTFail("Element never became hittable: \(element)")
    }

    private func scrollToTop() {
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<20 { scrollView.swipeDown() }
    }

    private func openCustomization(for tile: XCUIElement) {
        XCTAssertTrue(tile.waitForExistence(timeout: 3))
        if !tile.isHittable { scrollUntilHittable(tile, direction: .up) }
        tile.rightClick()
        let item = app.menuItems["Customize Tile…"]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()
        XCTAssertTrue(
            app.textFields["customization-display-name-field"].waitForExistence(timeout: 3)
        )
    }

    private func replaceText(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        if text.isEmpty {
            field.typeKey(.delete, modifierFlags: [])
        } else {
            field.typeText(text)
        }
    }

    private func waitForLabel(_ label: String, on element: XCUIElement, timeout: TimeInterval) {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func toggle(_ element: XCUIElement) {
        let oldValue = toggleState(element)
        XCTAssertNotNil(oldValue, "Toggle exposed an unsupported value: \(String(describing: element.value))")
        element.click()
        XCTAssertNotEqual(toggleState(element), oldValue)
    }

    private func setConfirmBeforeTake(_ enabled: Bool) {
        app.typeKey(",", modifierFlags: .command)
        let toggle = app.switches["settings-confirm-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        guard let isOn = toggleState(toggle) else {
            XCTFail("Confirm toggle exposed an unsupported value: \(String(describing: toggle.value))")
            app.typeKey("w", modifierFlags: .command)
            return
        }
        if isOn != enabled { toggle.click() }
        app.typeKey("w", modifierFlags: .command)
    }

    private func toggleState(_ element: XCUIElement) -> Bool? {
        switch element.value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            if value == "1" || value.caseInsensitiveCompare("true") == .orderedSame {
                return true
            }
            if value == "0" || value.caseInsensitiveCompare("false") == .orderedSame {
                return false
            }
            return nil
        default:
            return nil
        }
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func startMockServer(size: Int) throws -> Int {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serverScript = repositoryRoot
            .appendingPathComponent("TestSupport")
            .appendingPathComponent("mock_videohub_server.py")

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-u", serverScript.path,
            "--host", "127.0.0.1",
            "--port", "0",
            "--size", String(size)
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        mockServer = process

        let readiness = MockServerReadiness()
        let readyExpectation = expectation(description: "Mock Videohub server became ready")
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if readiness.append(data), readiness.markExpectationFulfilled() {
                readyExpectation.fulfill()
            }
        }

        let result = XCTWaiter.wait(for: [readyExpectation], timeout: 5)
        output.fileHandleForReading.readabilityHandler = nil
        guard result == .completed,
              process.isRunning,
              let port = readiness.port else {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            mockServer = nil
            XCTFail("Mock server did not become ready: \(readiness.text)")
            throw MockServerError.failedToStart
        }
        return port
    }
}

private enum MockServerError: Error {
    case failedToStart
}

private final class MockServerReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    private var expectationFulfilled = false

    var text: String {
        lock.withLock { storage }
    }

    var port: Int? {
        lock.withLock {
            guard let readyRange = storage.range(of: "READY 127.0.0.1:"),
                  let end = storage[readyRange.upperBound...].firstIndex(where: {
                      !$0.isNumber
                  }) else { return nil }
            return Int(storage[readyRange.upperBound..<end])
        }
    }

    func append(_ data: Data) -> Bool {
        lock.withLock {
            storage += String(decoding: data, as: UTF8.self)
            return storage.contains("READY 127.0.0.1:") && storage.contains("\n")
        }
    }

    func markExpectationFulfilled() -> Bool {
        lock.withLock {
            guard !expectationFulfilled else { return false }
            expectationFulfilled = true
            return true
        }
    }
}
