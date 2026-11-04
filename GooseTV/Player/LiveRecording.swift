import Foundation

/// A transport stream kept on the server (a recording made off the air),
/// read by the byte, and the one thing that says where a moment in it lies:
/// the stream's own clock, which every transport stream carries a few times
/// a second.
///
/// A broadcast isn't sent at an even pace: the same minute may be twice the
/// bytes of the next. So "a third of the way through the file" is not a
/// third of the way through the programme (measured on an hour of news, out
/// by as much as 79 seconds), and a player that goes to a time by going to
/// that fraction of the file lands somewhere near it. The place for a time
/// is found here instead: guessed from the file's average pace, the clock
/// read there, and the guess put right by how far out it was. Two or three
/// goes land within a second.
class TransportFile: @unchecked Sendable {
    fileprivate let file: URLRequest
    fileprivate let session: URLSession
    fileprivate let lock = NSLock()
    /// The clock at the file's first packet to carry one, and which of the
    /// stream's parts it rides on: the same part is read for it throughout.
    private var first: (clock: Double, pid: Int)?
    /// A file that's finished is measured once.
    private var whole: (seconds: Double, size: Int64)?
    /// Still being written: its length is asked afresh each time.
    fileprivate var grows: Bool { false }

    init(file: URLRequest) {
        self.file = file
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: Asking the server

    fileprivate struct Piece {
        let status: Int
        let data: Data
        /// How big the whole file is now, where the server said.
        let whole: Int64?
    }

    /// Bytes of the file from a place, as many as are asked for or as there
    /// are. Waits for the answer: for a thread of its own, never the main one.
    fileprivate func fetch(from offset: Int64, count: Int) -> Piece? {
        var request = file
        request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        return send(request).map { answer in
            // "bytes 0-999/28343328", or "bytes */28343328" past the end.
            let range = answer.response.value(forHTTPHeaderField: "Content-Range")
            let whole = range?.split(separator: "/").last.flatMap { Int64($0) }
            return Piece(status: answer.response.statusCode, data: answer.data, whole: whole)
        }
    }

    fileprivate func send(_ request: URLRequest) -> (data: Data, response: HTTPURLResponse)? {
        let done = DispatchSemaphore(value: 0)
        var answer: (Data, HTTPURLResponse)?
        session.dataTask(with: request) { data, response, _ in
            if let data, let response = response as? HTTPURLResponse { answer = (data, response) }
            done.signal()
        }.resume()
        done.wait()
        return answer
    }

    // MARK: The stream's clock

    fileprivate static let packet = 188

    /// The clocks in a run of the stream, each with where its packet starts
    /// in the run: seconds, as the stream counts them.
    fileprivate static func clocks(in data: Data, pid wanted: Int?) -> [(clock: Double, at: Int, pid: Int)] {
        var found: [(Double, Int, Int)] = []
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let count = bytes.count
            // Its footing: a packet begins with 0x47, and so do the two
            // after it. (The file needn't begin on a packet's edge: the
            // server starts writing wherever the stream had got to.)
            var at = 0
            while at + 2 * packet < count,
                  !(bytes[at] == 0x47 && bytes[at + packet] == 0x47 && bytes[at + 2 * packet] == 0x47) { at += 1 }
            while at + packet <= count {
                defer { at += packet }
                guard bytes[at] == 0x47 else { continue }
                let pid = (Int(bytes[at + 1]) & 0x1F) << 8 | Int(bytes[at + 2])
                // An adaptation field, long enough for a clock, with one in it.
                guard bytes[at + 3] & 0x20 != 0, bytes[at + 4] >= 7, bytes[at + 5] & 0x10 != 0 else { continue }
                if let wanted, pid != wanted { continue }
                let base = UInt64(bytes[at + 6]) << 25 | UInt64(bytes[at + 7]) << 17 | UInt64(bytes[at + 8]) << 9
                    | UInt64(bytes[at + 9]) << 1 | UInt64(bytes[at + 10]) >> 7
                found.append((Double(base) / 90_000, at, pid))
            }
        }
        return found
    }

    /// The clock runs to 2^33 ninety-thousandths of a second and begins
    /// again: a little over a day. A reading below the file's first is one
    /// from after it turned over.
    fileprivate static let turn = Double(UInt64(1) << 33) / 90_000

    fileprivate func since(_ start: Double, _ clock: Double) -> Double {
        clock >= start ? clock - start : clock + Self.turn - start
    }

    fileprivate var firstClock: (clock: Double, pid: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return first
    }

    /// How long the file runs and how big it is, by its first clock and its
    /// last. Asks the server two or three times: for a thread that may wait.
    @discardableResult
    func measure() -> (seconds: Double, size: Int64)? {
        lock.lock()
        let known = whole
        lock.unlock()
        if let known, !grows { return known }
        var start = firstClock
        if start == nil {
            guard let head = fetch(from: 0, count: 512 * 1024), head.status == 206,
                  let clock = Self.clocks(in: head.data, pid: nil).first else { return nil }
            start = (clock.clock, clock.pid)
            lock.lock()
            first = start
            lock.unlock()
        }
        guard let start else { return nil }
        // The newest half-megabyte, to the last clock in it.
        guard let probe = fetch(from: 0, count: 1), let size = probe.whole, size > 0 else { return nil }
        let from = max(size - 512 * 1024, 0) / Int64(Self.packet) * Int64(Self.packet)
        guard let tail = fetch(from: from, count: 512 * 1024 + Self.packet), tail.status == 206,
              let last = Self.clocks(in: tail.data, pid: start.pid).last else { return nil }
        let measured = (since(start.clock, last.clock), from + Int64(last.at))
        lock.lock()
        whole = measured
        lock.unlock()
        measuring(measured.0)
        return measured
    }

    /// Told each time the file has been measured, with how long it runs.
    fileprivate func measuring(_ seconds: Double) {}

    /// Where in the file the picture of so many seconds from its first
    /// clock begins, with how big the file is: nil where it can't be read.
    /// Its first byte for a moment before its start, its last for one past
    /// its end.
    func place(atSeconds wanted: Double) -> (offset: Int64, size: Int64)? {
        guard let (seconds, size) = measure(), seconds > 0, let start = firstClock else { return nil }
        if wanted <= 1 { return (0, size) }
        if wanted >= seconds - 0.5 { return (size, size) }
        let pace = Double(size) / seconds
        var guess = Int64(pace * wanted)
        var best: (offset: Int64, off: Double)?
        for _ in 0..<5 {
            guess = min(max(guess, 0), max(size - 256 * 1024, 0)) / Int64(Self.packet) * Int64(Self.packet)
            guard let piece = fetch(from: guess, count: 256 * 1024), piece.status == 206,
                  let clock = Self.clocks(in: piece.data, pid: start.pid).first else { break }
            let off = wanted - since(start.clock, clock.clock)
            let here = guess + Int64(clock.at)
            if best == nil || abs(off) < abs(best!.off) { best = (here, off) }
            if abs(off) < 0.75 { break }
            guess = here + Int64(off * pace)
        }
        return (best?.offset ?? Int64(pace * wanted) / Int64(Self.packet) * Int64(Self.packet), size)
    }

    /// The stream's clock at a place in the file, in seconds from its
    /// first: what the picture at that byte is the picture of.
    func seconds(atOffset offset: Int64) -> Double? {
        guard measure() != nil, let start = firstClock else { return nil }
        let from = max(offset, 0) / Int64(Self.packet) * Int64(Self.packet)
        guard let piece = fetch(from: from, count: 256 * 1024), piece.status == 206,
              let clock = Self.clocks(in: piece.data, pid: start.pid).first else { return nil }
        return since(start.clock, clock.clock)
    }
}

/// A programme the server is recording this minute, read from the
/// recording itself: the way back to its beginning for someone who sat down
/// late. What a channel has sent since it was tuned is kept on the device
/// (`LiveBuffer`), and that reaches no further back than the tuning; the
/// server has had the programme from its first minute.
///
/// The server hands the file over a piece at a time, by the byte, while it
/// is still being written, and says how big it has got with each piece. So
/// the newest end is read by asking again for what wasn't there a moment
/// ago, and a moment in it is found by the stream's own clock (see
/// `TransportFile`): the place for "twenty minutes ago" is the place whose
/// clock reads twenty minutes short of the newest.
final class LiveRecording: TransportFile, @unchecked Sendable {
    /// What a feed reads it by: the next of it, nil when there's no more.
    typealias Reader = (_ stopped: () -> Bool) -> Data?

    /// The timer it's being made for.
    let timerId: String
    /// Asked whether the recording is still going, when the file stops growing.
    private let stillGoing: URLRequest?
    /// When its first picture went out, by this device's clock: settled the
    /// first time it's measured, while it's still growing and its newest is
    /// this moment's. (Measured after it has ended, its newest is whenever
    /// that was.)
    private var start: Date?
    private var over = false
    /// Told once when the recording has ended and all of it has been read.
    var onOver: (@Sendable () -> Void)?

    override fileprivate var grows: Bool { true }

    init(timerId: String, file: URLRequest, stillGoing: URLRequest?) {
        self.timerId = timerId
        self.stillGoing = stillGoing
        super.init(file: file)
    }

    override fileprivate func measuring(_ seconds: Double) {
        lock.lock()
        if start == nil { start = Date().addingTimeInterval(-seconds) }
        lock.unlock()
    }

    /// When its first picture went out, by this device's clock: reckoned
    /// from how long the file runs. Nil until it's been measured.
    var began: Date? {
        lock.lock()
        defer { lock.unlock() }
        return start
    }

    /// No more of it is coming, and a reader has reached its end.
    var isOver: Bool {
        lock.lock()
        defer { lock.unlock() }
        return over
    }

    /// Done with: a reader waiting for more gives up.
    func stop() {
        lock.lock()
        over = true
        onOver = nil
        lock.unlock()
    }

    /// Whether the server is still recording it. True where that can't be
    /// told (the server not answering): a file that has only paused is
    /// waited on. A timer that's done with is gone, and asked for by name
    /// the server answers that there's nothing: `null`, and no complaint.
    private func isStillGoing() -> Bool {
        guard let stillGoing, let answer = send(stillGoing) else { return true }
        if answer.response.statusCode >= 500 { return true }
        guard answer.response.statusCode == 200,
              let timer = try? JSONSerialization.jsonObject(with: answer.data) as? [String: Any] else { return false }
        return timer["Status"] as? String == "InProgress"
    }

    /// Where in the file the picture of so many seconds ago begins. So many
    /// seconds before this moment, not before the file's newest: the two
    /// are one while the recording goes on, and part once it has ended,
    /// when a moment since isn't in the file at all (its end is given, and
    /// a reader there finds that it's over).
    private func place(behind: TimeInterval) -> Int64? {
        guard measure() != nil, let began else { return nil }
        return place(atSeconds: Date().addingTimeInterval(-behind).timeIntervalSince(began))?.offset
    }

    // MARK: Reading

    /// The file from so far before its newest (from its first byte for nil
    /// or for more than there is), and on as it grows. The place is found on
    /// the first call, which may wait on the server a few times: for a
    /// feed's own thread.
    func reader(behind: TimeInterval?) -> Reader {
        var offset: Int64?
        var quiet: Date?
        var asked = Date.distantPast
        var failures = 0
        var refusals = 0
        return { [self] stopped in
            if offset == nil {
                offset = behind.flatMap { self.place(behind: $0) } ?? 0
            }
            while !stopped(), !isOver {
                guard let piece = fetch(from: offset!, count: 1024 * 1024) else {
                    // The server couldn't be reached this time.
                    failures += 1
                    if failures > 20 { return nil }
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                failures = 0
                if piece.status == 206, !piece.data.isEmpty {
                    quiet = nil
                    refusals = 0
                    offset! += Int64(piece.data.count)
                    return piece.data
                }
                // Nothing new yet: it's read as fast as it's written. Or
                // nothing more ever, the programme being over. Or the server
                // won't hand it over any more (the recording deleted, the
                // account signed out): that's the end of it too, once it has
                // said so a few times running.
                let since = quiet ?? Date()
                quiet = since
                var done = Date().timeIntervalSince(since) > 60
                if piece.status != 206, piece.status != 416 {
                    refusals += 1
                    done = done || refusals >= 3
                } else {
                    refusals = 0
                }
                if !done, Date().timeIntervalSince(since) > 1.5, Date().timeIntervalSince(asked) > 3 {
                    asked = Date()
                    done = !isStillGoing()
                }
                if done {
                    lock.lock()
                    let told = over ? nil : onOver
                    over = true
                    onOver = nil
                    lock.unlock()
                    told?()
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
            return nil
        }
    }
}
