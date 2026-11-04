import XCTest
/// Signs the simulator in to the real server by Quick Connect, approved by hand.
final class QuickConnectUITests: XCTestCase {
    func shot(_ name: String) { try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/jellygoose-shots/" + name)) }
    func testSignInByQuickConnect() {
        let app = XCUIApplication()
        // A wrong password leaves the app on this server's sign-in screen.
        app.launchEnvironment = ["GOOSETV_SERVER": "http://192.168.1.10:8096", "GOOSETV_USER": "nobody", "GOOSETV_PASS": "wrong"]
        app.launch()
        let getCode = app.buttons["Get a code"]
        XCTAssertTrue(getCode.waitForExistence(timeout: 30), "no Quick Connect on the sign-in screen")
        let remote = XCUIRemote.shared
        for _ in 0..<6 where !getCode.hasFocus { remote.press(.right); sleep(1) }
        remote.press(.select); sleep(4)
        shot("qc-code.png")
        // Wait for the approval: Home's menu appears once signed in.
        let home = app.staticTexts["Continue Watching"]
        XCTAssertTrue(home.waitForExistence(timeout: 900), "not approved in time")
        sleep(5)
        shot("qc-home.png")
    }
}
