/*
    Licensed to the Apache Software Foundation (ASF) under one
    or more contributor license agreements.  See the NOTICE file
    distributed with this work for additional information
    regarding copyright ownership.  The ASF licenses this file
    to you under the Apache License, Version 2.0 (the
    "License"); you may not use this file except in compliance
    with the License.  You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing,
    software distributed under the License is distributed on an
    "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
    KIND, either express or implied.  See the License for the
    specific language governing permissions and limitations
    under the License.
*/

import XCTest

final class SecondaryTouchUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["CDV_SECONDARY_TOUCH_UI_TEST"] = "1"
        if name.contains("testMainWithoutSecondaryControl") { app.launchEnvironment["CDV_TOUCH_CONTROL"] = "1" }
        if name.contains("testBackgroundDuringTouch") { XCUIApplication(bundleIdentifier: "com.apple.Preferences").activate() }
        app.launch()
        XCTAssertTrue(app.staticTexts["Touch test ready"].waitForExistence(timeout: 20))
    }

    private func expect(_ text: String) {
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 5), app.debugDescription)
    }

    func testMainWithoutSecondaryControl() { checkBackgroundCycles() }

    func testBackgroundForegroundKeepsMainTouchable() { checkBackgroundCycles() }

    private func checkBackgroundCycles() {
        for count in 1...4 {
            app.buttons["Tap main"].tap()
            expect("Main taps: \(count)")
            XCUIDevice.shared.press(.home)
            app.activate()
            Thread.sleep(forTimeInterval: 1)
        }
        app.buttons["Tap main"].tap()
        expect("Main taps: 5")
    }

    func testBackgroundDuringTouchKeepsMainTouchable() {
        for count in 1...2 {
            app.buttons["Arm background"].tap()
            XCTAssertTrue(app.buttons["Background armed"].waitForExistence(timeout: 5))
            app.buttons["Tap main"].press(forDuration: 3)
            XCTAssertEqual(app.state, .runningBackground)
            app.activate()
            Thread.sleep(forTimeInterval: 1)
            expect("Main starts: \(count * 2 - 1)")
            expect("Main taps: \(count - 1)")
            app.buttons["Tap main"].tap()
            expect("Main taps: \(count)")
        }
    }

    func testRegionUpdateDuringTouchCancelsAndReroutes() {
        let target = app.buttons["Tap main"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        app.buttons["Arm region update"].tap()
        XCTAssertTrue(app.buttons["Region update armed"].waitForExistence(timeout: 5))
        target.press(forDuration: 0.35)
        expect("Region update applied")
        expect("Main taps: 0")
        target.tap()
        expect("Secondary taps: 1")
    }

    func testHeldTapWithoutRegionUpdateIsDelivered() {
        app.buttons["Tap main"].press(forDuration: 0.35)
        expect("Main taps: 1")
    }

    func testRegionUpdateWithoutTouchDoesNotCancel() {
        let target = app.buttons["Tap main"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        app.buttons["Route secondary"].tap()
        expect("Main cancels: 0")
        expect("Secondary cancels: 0")
        target.tap()
        expect("Secondary taps: 1")
    }
}
