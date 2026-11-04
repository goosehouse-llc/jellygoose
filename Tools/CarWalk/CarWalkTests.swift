import XCTest
import CarPlay
@testable import JellyGoose

/// Walks the car's screens without a car: reads the lists the app would hand
/// to CarPlay and presses their rows' handlers. Nothing is played.
@MainActor
final class CarWalkTests: XCTestCase {
    func rows(_ list: CPListTemplate) -> [CPListItem] {
        list.sections.flatMap { $0.items.compactMap { $0 as? CPListItem } }
    }
    func say(_ what: String, _ list: CPListTemplate, cap: Int, show: Int = 8) {
        let all = rows(list)
        let heads = list.sections.map { "\($0.header ?? "–")(\($0.items.count))" }.joined(separator: ", ")
        let some = all.prefix(show).map { row in row.detailText.map { "\(row.text ?? "?") [\($0)]" } ?? (row.text ?? "?") }
        let tail = all.count > show ? " … \(all.last?.text ?? "?")" : ""
        print("CAR \(what): \(all.count) rows \(all.count <= cap ? "" : "OVER THE LIMIT of \(cap) ") | sections: \(heads) | \(some.joined(separator: " · "))\(tail)")
        XCTAssertLessThanOrEqual(all.count, cap, what)
    }
    func press(_ row: CPListItem) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            guard let handler = row.handler else { return done.resume() }
            handler(row) { done.resume() }
        }
        try? await Task.sleep(for: .milliseconds(300))
    }
    func find(_ text: String, in list: CPListTemplate) -> CPListItem? { rows(list).first { $0.text == text } }
    /// The letter's own row, going into the group of letters that holds it first if they're grouped.
    func letter(_ letter: String, in list: CPListTemplate) async -> CPListItem? {
        if let row = find(letter, in: list) { return row }
        for group in rows(list) where (group.text ?? "").contains(" – ") {
            let ends = (group.text ?? "").components(separatedBy: " – ")
            if ends.count == 2, ends[0] <= letter, letter <= ends[1] || ends[0] == "#" {
                await press(group)
                if let row = find(letter, in: list) { return row }
            }
        }
        return nil
    }

    func walk(cap: Int) async {
        print("CAR ===== a car whose lists hold \(cap) rows =====")
        CarPlaySceneDelegate.rowLimitForTesting = cap
        let car = CarPlaySceneDelegate()
        car.reloadForTesting()
        let home = car.rootListsForTesting[0], libraries = car.rootListsForTesting[1]
        for _ in 0..<40 where rows(libraries).isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        say("Home", home, cap: cap)
        say("Libraries", libraries, cap: cap)

        // Movies → S → a stretch → a title's page, and back out of the stretch.
        guard let movies = find("Movies", in: libraries) else { return XCTFail("no Movies row") }
        await press(movies)
        guard let library = car.pushedForTesting.last as? CPListTemplate else { return XCTFail("no library screen") }
        say("Movies", library, cap: cap, show: 12)
        guard let s = await letter("S", in: library) else { return XCTFail("no S row") }
        say("Movies (where S is)", library, cap: cap, show: 12)
        await press(s)
        guard let shelf = car.pushedForTesting.last as? CPListTemplate, shelf !== library else { return XCTFail("no letter screen") }
        say("Movies · S", shelf, cap: cap, show: 14)
        var depth = 0
        // Into the stretch that holds "Star Wars", as far in as it takes.
        while let stretch = rows(shelf).first(where: { ($0.detailText ?? "").contains("movie") && !($0.text ?? "").isEmpty
            && ($0.text ?? "").hasPrefix("St") }) ?? rows(shelf).dropFirst(depth == 0 ? 0 : 1).first(where: { ($0.detailText ?? "").contains("movie") }),
              depth < 4, stretch.accessoryType == .disclosureIndicator, (stretch.detailText ?? "").contains("movie") {
            await press(stretch)
            depth += 1
            say("  into \(stretch.text ?? "?") (step \(depth))", shelf, cap: cap, show: 6)
            if rows(shelf).contains(where: { ($0.detailText ?? "").count == 4 }) { break }   // titles show a year
        }
        if let title = rows(shelf).first(where: { ($0.detailText ?? "").count == 4 }) {
            let before = car.pushedForTesting.count
            await press(title)
            if car.pushedForTesting.count > before, let page = car.pushedForTesting.last as? CPListTemplate {
                print("CAR   a title's page: \(page.title ?? "?") | rows \(rows(page).map { $0.text ?? "?" })")
            } else { XCTFail("the title's page didn't open") }
        } else { XCTFail("no titles reached under S") }
        if depth > 0, let back = rows(shelf).first {
            await press(back)
            say("  back out (\(back.text ?? "?"))", shelf, cap: cap, show: 6)
        }

        // Shows → B → Bluey → Season 1: a long list a screenful at a time.
        guard let showsRow = find("Shows", in: libraries) else { return XCTFail("no Shows row") }
        await press(showsRow)
        guard let shows = car.pushedForTesting.last as? CPListTemplate else { return }
        say("Shows", shows, cap: cap, show: 10)
        if let season = rows(shows).first(where: { ($0.detailText ?? "").hasPrefix("Season") }) {
            let before = car.pushedForTesting.count
            await press(season)
            if car.pushedForTesting.count > before, let list = car.pushedForTesting.last as? CPListTemplate {
                say("  a season among Recently Added (\(season.text ?? "?") · \(season.detailText ?? "?"))", list, cap: cap, show: 3)
            } else { XCTFail("a season row opened nothing") }
        }
        guard let b = await letter("B", in: shows) else { return XCTFail("no B row") }
        await press(b)
        guard let bShelf = car.pushedForTesting.last as? CPListTemplate else { return }
        say("Shows · B", bShelf, cap: cap, show: 6)
        var steps = 0
        while find("Bluey", in: bShelf) == nil, steps < 4 {
            // The stretch whose guide words span "Bluey".
            let stretches = rows(bShelf).filter { ($0.detailText ?? "").contains("show") }
            guard let next = stretches.last(where: { (($0.text ?? "").components(separatedBy: " – ").first ?? "").lowercased() <= "bluey" }) ?? stretches.first else { break }
            await press(next); steps += 1
            say("  into \(next.text ?? "?")", bShelf, cap: cap, show: 6)
        }
        guard let bluey = find("Bluey", in: bShelf) else { return XCTFail("Bluey not reached under B") }
        await press(bluey)
        guard let page = car.pushedForTesting.last as? CPListTemplate, page !== bShelf else { return XCTFail("no show page") }
        say("Bluey's page", page, cap: cap, show: 6)
        guard let season = rows(page).first(where: { ($0.text ?? "").contains("1") }) else { return XCTFail("no season row") }
        await press(season)
        guard let episodes = car.pushedForTesting.last as? CPListTemplate, episodes !== page else { return XCTFail("no season screen") }
        say("\(season.text ?? "?")", episodes, cap: cap, show: 4)
        if let more = find("More", in: episodes) {
            await press(more)
            say("  More", episodes, cap: cap, show: 4)
            if let previous = find("Previous", in: episodes) {
                await press(previous)
                say("  Previous", episodes, cap: cap, show: 4)
            } else { XCTFail("no Previous row after More") }
        }
    }

    func testWalk() async {
        print("CAR what the system says with no car: maximumItemCount \(CPListTemplate.maximumItemCount), maximumSectionCount \(CPListTemplate.maximumSectionCount)")
        await walk(cap: 500)
        await walk(cap: 24)
        await walk(cap: 12)
    }
}
