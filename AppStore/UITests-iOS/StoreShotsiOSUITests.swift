import UIKit
import XCTest
/// The App Store's iPhone and iPad sets, from a simulator signed in to the
/// real server as the JellyGoose profile: a 6.9-inch iPhone upright (its
/// player on its side) and a 13-inch iPad on its side.
final class StoreShotsiOSUITests: XCTestCase {
    var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    var env: [String: String] { ProcessInfo.processInfo.environment }

    func shot(_ name: String) {
        let folder = "/tmp/jellygoose-shots/ios"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "\(folder)/\(pad ? "ipad" : "iphone")-\(name).png"))
    }
    func launch(_ hooks: [String: String] = [:], arguments: [String] = [], settle: UInt32 = 12) -> XCUIApplication {
        if pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = XCUIApplication()
        app.launchArguments = arguments
        var hooks = hooks
        // A simulator that isn't signed in yet is signed in by the app's own
        // hook, given where and as whom.
        if let server = env["JG_SERVER"] {
            hooks["GOOSETV_SERVER"] = server
            hooks["GOOSETV_USER"] = env["JG_USER"] ?? ""
            hooks["GOOSETV_PASS"] = env["JG_PASS"] ?? ""
        }
        app.launchEnvironment = hooks
        app.launch()
        sleep(settle)
        // The first launch after the version changes shows What's New.
        let go = app.buttons["Continue"]
        if go.exists { go.tap(); sleep(2) }
        return app
    }
    /// The one of a name highest on the screen: a page's own Search button
    /// and not the tab bar's.
    func topmost(_ name: String, in app: XCUIApplication) -> XCUIElement? {
        app.buttons.matching(identifier: name).allElementsBoundByIndex
            .filter { $0.exists && $0.frame.height > 0 }
            .min { $0.frame.minY < $1.frame.minY }
    }

    func test1Matrix() {
        _ = launch(["GOOSETV_ITEM": "a3eacd4a8043c8c04b9af0b7adb474f8"])   // The Matrix Resurrections, 4K
        sleep(4)
        shot("01-matrix")
    }
    /// Home, while its banner is still on the first of what's part-watched:
    /// it moves on to the next every few seconds.
    func test2Home() {
        _ = launch(settle: 6)
        shot("02-home")
    }
    func test3Show() {
        _ = launch(["GOOSETV_ITEM": "173e3852094c6e8bb6b4b0b830d0814f"])   // Bluey
        sleep(4)
        shot("03-show")
    }
    func test4Library() {
        let app = launch(["GOOSETV_TAB": "library:f137a2dd21bbc1b99aa5c0f6bf02a805"])   // Movies
        let letter = app.buttons["Jump to B"]
        XCTAssertTrue(letter.waitForExistence(timeout: 20), "no letters down the side")
        letter.tap()
        sleep(10)
        shot("04-library")
    }
    /// 13 Hours resumed, the phone on its side, the controls up. Its position
    /// moves on while this runs: put it back afterwards.
    func test5Player() {
        let app = launch(["GOOSETV_ITEM": "4753004e3ccfdea810113f8d6259a4f4"])
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume' OR label BEGINSWITH 'Play'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 40), "no Resume button")
        play.tap()
        sleep(2)
        if !pad { XCUIDevice.shared.orientation = .landscapeLeft }
        sleep(18)
        let centre = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
        let close = app.buttons["Close"]
        // A few, some seconds apart, to choose one from: a line of dialogue
        // on screen is drawn up among the buttons while the controls are up.
        for n in 1...5 {
            if !close.exists { centre.tap(); sleep(1) }
            shot("05-player-\(n)")
            sleep(5)
        }
        if !close.exists { centre.tap(); sleep(1) }
        if close.exists { close.tap() }
        sleep(3)
        if !pad { XCUIDevice.shared.orientation = .portrait; sleep(2) }
    }
    func test6Downloads() {
        _ = launch(["GOOSETV_TAB": "downloads"])
        sleep(3)
        shot("06-downloads")
    }
    /// Requests, connected first where this simulator hasn't been.
    func test7Requests() {
        let app = launch(["GOOSETV_TAB": "requests"])
        let connect = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Connect to")).firstMatch
        if connect.exists { connect.tap(); sleep(16) }
        sleep(8)
        shot("07-requests")
    }
    /// The asking panel over a show the library hasn't got. Opened and
    /// cancelled: the page's Request button is tapped the once, to open the
    /// panel, and the panel's own never.
    func test8Asking() {
        let wanted = env["ASK_FOR"] ?? "The Good Place"
        let app = launch(["GOOSETV_TAB": "requests"])
        sleep(6)
        guard let search = topmost("Search", in: app) else { return XCTFail("no Search on the page") }
        search.tap(); sleep(3)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field")
        field.tap(); sleep(1)
        field.typeText(wanted.lowercased()); sleep(8)
        let found = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", wanted)).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: 15), "not found")
        found.tap(); sleep(8)
        let ask = app.buttons["Request"]
        XCTAssertTrue(ask.exists, "the page isn't offering to ask")
        guard ask.exists, app.buttons.matching(identifier: "Request").count == 1 else { return }
        ask.tap(); sleep(6)
        shot("08-asking")
        let cancel = app.buttons["Cancel"]
        if cancel.exists { cancel.tap(); sleep(2) }
    }
    /// Live TV: the guide, with the channel that's on playing over it. The
    /// home server's own tuner is behind it, so the picture is whatever is
    /// on the air: a few are taken, to choose from. `LIVE_CHANNEL`, a
    /// channel's id, is the one the page opens on. Left by way of Home,
    /// which lets the tuner go: ended on the guide, the test would leave it
    /// held for nobody.
    func test9LiveTV() {
        var arguments: [String] = []
        if let channel = env["LIVE_CHANNEL"] { arguments = ["-goosetv.liveTV.lastChannel", channel] }
        let app = launch(["GOOSETV_TAB": "livetv"], arguments: arguments)
        sleep(10)
        for n in 1...6 {
            shot("09-livetv-\(n)")
            sleep(4)
        }
        // Every button called Home, until the guide has gone: an iPad has
        // more than one, and the first isn't the one in its rail.
        let guide = app.buttons["All Channels"]
        let homes = app.buttons.matching(identifier: "Home").allElementsBoundByIndex
        print("PROBE home buttons:", homes.map { "\($0.frame) hittable \($0.isHittable)" })
        for home in homes where guide.exists && home.isHittable {
            home.tap()
            sleep(2)
        }
        print("PROBE the guide has gone:", !guide.exists)
        XCTAssertFalse(guide.exists, "still on Live TV: the tuner is held")
        sleep(6)
    }
    /// Live TV filling the screen, its controls up: the phone on its side.
    /// The guide's picture of the channel that's on is pressed to get there
    /// (`PREVIEW`, where it is as fractions of the screen, "x,y"). For the
    /// store, the throwaway server's made-up channels, whose pictures are
    /// nobody's programmes (fakehdhr.py with FANCY=1).
    func test10LiveFull() {
        var arguments: [String] = []
        if let channel = env["LIVE_CHANNEL"] { arguments = ["-goosetv.liveTV.lastChannel", channel] }
        let app = launch(["GOOSETV_TAB": "livetv"], arguments: arguments)
        sleep(10)
        let at = (env["PREVIEW"] ?? (pad ? "0.82,0.2" : "0.5,0.2")).split(separator: ",").compactMap { Double($0) }
        app.coordinate(withNormalizedOffset: CGVector(dx: at[0], dy: at[1])).tap()
        sleep(4)
        if !pad { XCUIDevice.shared.orientation = .landscapeLeft }
        sleep(8)
        // Up come the controls, and a few pictures are taken while they're up.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        sleep(1)
        for n in 1...3 {
            shot("10-livefull-\(n)")
            sleep(1)
        }
        let close = app.buttons["Close"]
        if !close.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap(); sleep(1) }
        if close.exists { close.tap(); sleep(3) }
        XCUIDevice.shared.orientation = pad ? .landscapeLeft : .portrait
        sleep(2)
        let homes = app.buttons.matching(identifier: "Home").allElementsBoundByIndex
        for home in homes where app.buttons["All Channels"].exists && home.isHittable {
            home.tap()
            sleep(2)
        }
        sleep(4)
    }
    /// Music: Now Playing, about fifty seconds into the song. The album is a
    /// made-up one (Juniper Gale, "Northbound": `AppStore/music/`) on the
    /// throwaway server, so that no real artist's work is on the store page:
    /// MUSIC_ALBUM is its id there, and JG_SERVER, JG_USER and JG_PASS sign
    /// the simulator in to it. The iPhone shows the lyrics, at the chorus,
    /// with the cover above them; the iPad's lyrics leave the cover out, so
    /// the iPad shows the cover beside the controls instead.
    func test11Music() {
        let app = launch(["GOOSETV_ITEM": env["MUSIC_ALBUM"] ?? ""])
        app.buttons["Play"].firstMatch.tap()
        sleep(3)
        // The mini player opens Now Playing: a tap beside its Pause button.
        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.exists, "nothing playing")
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.width * 0.3, dy: pause.frame.midY)).tap()
        sleep(3)
        if !pad { app.buttons["Lyrics"].firstMatch.tap() }
        sleep(UInt32(env["MUSIC_WAIT"] ?? "44") ?? 44)
        shot("11-music")
        app.buttons["Pause"].firstMatch.tap()
    }
    /// For a simulator with nothing on it: downloads the two episodes the
    /// Downloads shot lists, and waits for them.
    func testSetUpDownloads() {
        for id in ["cd757294c4047e66880137899ea49cb3", "1caddfebd93f6b86cfdf8f21053a1b86"] {   // Bluey S1 E1, E2
            let app = launch(["GOOSETV_ITEM": id])
            let get = app.buttons["Download"]
            if get.waitForExistence(timeout: 20) { get.tap() }
            // The first download asks leave to say when it's done, and
            // doesn't start until it's told: answer, as a person would.
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
            if allow.waitForExistence(timeout: 6) { allow.tap() }
            XCTAssertTrue(app.buttons["Remove Download"].waitForExistence(timeout: 600), "still downloading \(id)")
            app.terminate()
        }
    }
}
