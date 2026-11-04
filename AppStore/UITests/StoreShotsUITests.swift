import XCTest
/// The App Store set, from the simulator signed in to the real server.
final class StoreShotsUITests: XCTestCase {
    let remote = XCUIRemote.shared
    func shot(_ name: String) { try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/jellygoose-shots/" + name + ".png")) }
    func launch(_ env: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = env
        app.launch()
        sleep(16)
        // The first launch after the version changes shows What's New.
        let go = app.buttons["Continue"]
        if go.exists && go.hasFocus { remote.press(.select); sleep(3) }
        return app
    }
    /// What has focus, to steer by name rather than by counting presses.
    func focused(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true")).label
    }

    func test1Matrix() {
        _ = launch(["GOOSETV_ITEM": "a3eacd4a8043c8c04b9af0b7adb474f8"])   // The Matrix Resurrections, 4K
        sleep(4)
        shot("01-matrix")
    }
    func test2Home() {
        let app = launch()
        shot("09-menu")                              // the menu open over Home
        remote.press(.right); sleep(6)               // into the content: the menu folds away
        shot("02-home")
    }
    /// The long-press menu, over Back to the Future in Movies4k's row. With
    /// the film part-watched, as Home's Continue Watching wants it for the
    /// two above, the menu is about resuming it: clear its position first.
    func test2LongPress() {
        let app = launch()
        remote.press(.right); sleep(6)
        for _ in 0..<6 where !focused(app).contains("Mission: Impossible - The") { remote.press(.down); sleep(2) }
        for _ in 0..<4 where !focused(app).hasPrefix("Back to the Future") { remote.press(.right); sleep(1) }
        sleep(2)
        remote.press(.select, forDuration: 1.4); sleep(3)
        shot("08-longpress")
    }
    /// Resumes Top Gun: Maverick where the account left it: set its position
    /// to chapter 14 (the helmet close-up, 1:57) first.
    func test3Player() {
        _ = launch(["GOOSETV_ITEM": "7c6c6701f50c75167a74abae28b5aaad"])
        sleep(2); remote.press(.select); sleep(28)   // Resume
        remote.press(.playPause); sleep(3)           // paused: the controls stay up
        remote.press(.up); sleep(2)                  // onto the row of buttons
        shot("03-player")
        remote.press(.menu); sleep(1); remote.press(.menu); sleep(2); remote.press(.menu); sleep(2)
    }
    func test3Movies4k() {
        let app = launch(["GOOSETV_TAB": "library:3bfa1069126e8cc3a0f038cf12196583"])   // Movies4k
        remote.press(.right); sleep(3)
        for _ in 0..<4 where !focused(app).hasPrefix("13 Hours") { remote.press(.left); sleep(1) }
        sleep(6)
        shot("04-movies4k")
    }
    func test4Alphabet() {
        let app = launch(["GOOSETV_TAB": "library:f137a2dd21bbc1b99aa5c0f6bf02a805"])   // Movies
        remote.press(.right); sleep(3)
        for _ in 0..<8 { remote.press(.right); usleep(500_000) }    // into the alphabet
        let m = app.buttons["Jump to B"]
        for _ in 0..<30 where !(m.exists && m.hasFocus) { remote.press(.down); usleep(450_000) }
        sleep(10)
        shot("05-library")
    }
    func test5Maverick() {
        _ = launch(["GOOSETV_ITEM": "7c6c6701f50c75167a74abae28b5aaad"])   // Top Gun: Maverick, 4K
        sleep(4)
        shot("06-maverick")
        for _ in 0..<3 { remote.press(.down); sleep(2) }
        sleep(3)
        shot("07-cast")
    }
    func test6Appearance() {
        let app = launch(["GOOSETV_TAB": "settings"])
        remote.press(.right); sleep(2)
        let tile = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Appearance")).firstMatch
        // From the menu's Settings row, at the bottom, focus lands low on the
        // page: up to the top of it first, then down to the tile.
        for _ in 0..<8 where !(tile.exists && tile.hasFocus) { remote.press(.up); usleep(700_000) }
        for _ in 0..<8 where !(tile.exists && tile.hasFocus) { remote.press(.down); sleep(1) }
        XCTAssertTrue(tile.hasFocus, "Appearance not reached")
        remote.press(.select); sleep(4)
        shot("10-appearance")
    }
    /// Requests, which a server with Seerr beside it has. Where this
    /// simulator hasn't connected to it yet, the page offers to and is taken
    /// up on it: signed in as the profile, with nothing to type.
    func test7Requests() {
        let app = launch(["GOOSETV_TAB": "requests"])
        let connect = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Connect to")).firstMatch
        if connect.exists {
            for _ in 0..<4 where !connect.hasFocus { remote.press(.right); sleep(1) }
            remote.press(.select); sleep(16)
        }
        remote.press(.right); sleep(10)              // into the page: the menu folds away
        // Onto the first of what's trending, from wherever in the page that
        // landed: up to the buttons at the page's head, down onto the row
        // (under the buttons, so well along it), and left to the card at the
        // screen's edge. One press more would be the menu's.
        let top = ["Search", "Your Requests", "All Requests"]
        for _ in 0..<6 where !top.contains(focused(app)) { remote.press(.up); sleep(1) }
        remote.press(.down); sleep(2)
        let lit = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        for _ in 0..<8 where lit.frame.minX > 300 { remote.press(.left); sleep(1) }
        sleep(4)
        shot("11-requests")
    }
    /// The asking panel, over a show the library hasn't got: its seasons to
    /// tick and the button that asks. Opened, looked at and closed again.
    /// Nothing is asked for: once the panel is up its Request button has
    /// focus, and no press of Select follows.
    func test7Asking() {
        let env = ProcessInfo.processInfo.environment
        // A show the home library hasn't got, with few enough seasons that
        // the panel lists them all without scrolling (six at the most).
        let wanted = env["ASK_FOR"] ?? "The Good Place"
        let app = launch(["GOOSETV_TAB": "requests"])
        remote.press(.right); sleep(8)               // into the page
        let top = ["Search", "Your Requests", "All Requests"]
        for _ in 0..<6 where !top.contains(focused(app)) { remote.press(.up); sleep(1) }
        for _ in 0..<3 where focused(app) != "Search" { remote.press(.right); sleep(1) }
        XCTAssertEqual(focused(app), "Search")
        remote.press(.select); sleep(4)              // the search, its keyboard up
        app.typeText(wanted.lowercased()); sleep(8)
        for _ in 0..<4 where !focused(app).hasPrefix(wanted) { remote.press(.down); sleep(2) }
        XCTAssertTrue(focused(app).hasPrefix(wanted), "found \(focused(app)) instead")
        remote.press(.select); sleep(8)              // its page, on Request
        XCTAssertEqual(focused(app), "Request", "the page isn't offering to ask")
        guard focused(app) == "Request" else { return }
        remote.press(.select); sleep(6)              // the panel
        shot("12-asking")
        remote.press(.menu); sleep(2)                // closed, unasked
        remote.press(.menu); sleep(2)
    }
    /// Music: Now Playing with the lyrics beside it, at the chorus. The album
    /// is a made-up one (Juniper Gale, "Northbound": `AppStore/music/`), on
    /// the throwaway server rather than the real one, so that no real
    /// artist's work is on the store page: MUSIC_ALBUM is its id there, and
    /// JG_SERVER, JG_USER and JG_PASS sign the simulator in to it.
    func test15Music() {
        let env = ProcessInfo.processInfo.environment
        var hooks = ["GOOSETV_ITEM": env["MUSIC_ALBUM"] ?? ""]
        if let server = env["JG_SERVER"] {
            hooks["GOOSETV_SERVER"] = server
            hooks["GOOSETV_USER"] = env["JG_USER"] ?? ""
            hooks["GOOSETV_PASS"] = env["JG_PASS"] ?? ""
        }
        let app = launch(hooks)
        // The album's page. Focus may still be in the menu, or come back on
        // a song in the list ("Title, 3:42"): over to the left and up to Play.
        for _ in 0..<8 where focused(app) != "Play" {
            let now = focused(app)
            if now.contains(":") || now == "Shuffle" { remote.press(.left) }
            else if app.buttons["Home"].hasFocus || app.buttons["Search"].hasFocus { remote.press(.right) }
            else { remote.press(.up) }
            sleep(1)
        }
        XCTAssertEqual(focused(app), "Play")
        remote.press(.select); sleep(4)                  // Now Playing, playing
        remote.press(.down); sleep(1)                    // the row of small buttons
        for _ in 0..<6 where focused(app) != "Lyrics" { remote.press(.left); sleep(1) }
        XCTAssertEqual(focused(app), "Lyrics")
        remote.press(.select); sleep(2)                  // the lyrics, beside
        remote.press(.up); sleep(1)                      // up to the controls, and along to Pause
        for _ in 0..<3 where focused(app) != "Pause" { remote.press(.right); sleep(1) }
        sleep(UInt32(env["MUSIC_WAIT"] ?? "40") ?? 40)   // into the chorus (0:50)
        shot("15-music")
        remote.press(.playPause)
    }
    /// Settings, Subtitles: the choices and the line that previews them.
    func test9Subtitles() {
        let app = launch(["GOOSETV_TAB": "settings"])
        remote.press(.right); sleep(2)
        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Subtitles")).firstMatch
        for _ in 0..<8 where !(tile.exists && tile.hasFocus) { remote.press(.up); usleep(700_000) }
        for _ in 0..<8 where !(tile.exists && tile.hasFocus) { remote.press(.down); sleep(1) }
        XCTAssertTrue(tile.hasFocus, "Subtitles not reached")
        remote.press(.select); sleep(4)
        shot("14-subtitles")
    }
    /// The Stats panel over a film that's playing, the controls gone. The
    /// film and how long to let it run can be given, to choose the frame.
    func test8Stats() {
        let env = ProcessInfo.processInfo.environment
        _ = launch(["GOOSETV_ITEM": env["STATS_ITEM"] ?? "7c6c6701f50c75167a74abae28b5aaad"])
        sleep(2); remote.press(.select)              // Resume
        sleep(UInt32(env["STATS_WAIT"] ?? "30") ?? 30)
        remote.press(.up); sleep(1)                  // onto the row of buttons
        for _ in 0..<8 { remote.press(.right); usleep(400_000) }    // Stats is its last
        remote.press(.select); sleep(1)              // the panel, on
        remote.press(.menu)                          // back to the picture
        sleep(UInt32(env["STATS_HOLD"] ?? "9") ?? 9) // the controls fade; the panel has read itself a few times
        shot("13-stats")
        remote.press(.menu); sleep(2); remote.press(.menu); sleep(2)
    }
}
