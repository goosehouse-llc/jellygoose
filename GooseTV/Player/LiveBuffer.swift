import Foundation

/// What a channel has sent since it was tuned, kept on the device so that
/// the picture can be taken back through it: a broadcast can't be asked for
/// again, and the server hands it over only as it arrives.
///
/// The stream is fetched here, not by the player, and written to a run of
/// short files, each stamped with when its first and last bytes came. The
/// player is fed from them (see `LiveFeed`): from the end to watch as it
/// goes out, from further back to see something again. Arriving as it's
/// broadcast, a stream's bytes are as good as a clock: what came a minute
/// ago is the picture of a minute ago.
///
/// It reaches back as far as the channel has been on, up to half an hour and
/// a few gigabytes, less where the device is short of room, and is gone
/// when the channel is left.
final class LiveBuffer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// A place in what's kept: a file, and how far into it.
    struct Place: Equatable {
        var piece: Int
        var offset: Int
    }

    private struct Piece {
        let index: Int
        let url: URL
        let began: Date
        var ended: Date
        var size: Int
    }

    /// How far back is kept, and how much room that may take.
    private let reach: TimeInterval
    private let most: Int64
    /// How long one file runs. Short, so that the oldest can be let go a
    /// little at a time, and so that a moment is found to within a few
    /// seconds by the file it's in.
    private static let span: TimeInterval = 8

    private let lock = NSCondition()
    private var pieces: [Piece] = []
    private var writing: FileHandle?
    /// No more is coming: it ended of its own accord, couldn't be kept, or
    /// was stopped.
    private var over = false
    /// `stop()` has run, and tidied.
    private var stopped = false
    private var failures = 0
    private var counter = 0
    private let folder: URL
    private var session: URLSession?
    /// Told once if the stream stops of its own accord: the tuner dropped
    /// it, or the server let it go.
    var onEnd: (@Sendable () -> Void)?
    /// Told once if what comes can't be kept (no room, as a rule): the
    /// stream is still there to be played the plain way.
    var onBroken: (@Sendable () -> Void)?

    init?(reach: TimeInterval = 30 * 60, most: Int64 = 4 << 30) {
        // A different length can be set by hand (`goosetv.liveTV.reach`, in
        // seconds): for trying it with a short one.
        let set = UserDefaults.standard.double(forKey: "goosetv.liveTV.reach")
        self.reach = set > 0 ? set : reach
        self.most = most
        folder = Self.home.appendingPathComponent(UUID().uuidString, isDirectory: true)
        super.init()
        Self.sweep()
        // Switched off (Settings, Live TV), nothing is kept at all: the
        // player fetches the stream itself, and shows it as it comes.
        if UserDefaults.standard.object(forKey: Self.switchKey) != nil, !UserDefaults.standard.bool(forKey: Self.switchKey) { return nil }
        // Nor on a device with next to no room: a channel that can't be
        // kept is still a channel to watch.
        let spare = (try? Self.home.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity
        if let spare, spare < 600_000_000 { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
    }

    private static let home = FileManager.default.temporaryDirectory.appendingPathComponent("LiveBuffer", isDirectory: true)

    /// Clears whatever an earlier run left: it was killed before it could
    /// tidy, and what it had kept may be gigabytes. Once in the life of the
    /// app, before anything of this run's is there: as the app starts, and
    /// again before the first channel in case that came first.
    static func sweep() {
        sweeping.lock()
        defer { sweeping.unlock() }
        guard !swept else { return }
        swept = true
        try? FileManager.default.removeItem(at: home)
    }

    private static let sweeping = NSLock()
    private static var swept = false
    /// Where the viewer's say on any of this is kept: on, unless it's been
    /// switched off.
    static let switchKey = "goosetv.liveTV.rewind"

    /// Begins fetching the stream.
    func start(_ url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Between one arrival and the next, not for the whole of it: it
        // never ends.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        session.dataTask(with: url).resume()
    }

    /// Done with: the fetching stops, what was kept is deleted, and anything
    /// waiting to read is told there's no more.
    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        over = true
        onEnd = nil
        onBroken = nil
        try? writing?.close()
        writing = nil
        pieces = []
        lock.broadcast()
        lock.unlock()
        // Once, and whether or not the stream had ended by itself first: a
        // stream that ended left its session and its files otherwise.
        guard !already else { return }
        session?.invalidateAndCancel()
        session = nil
        try? FileManager.default.removeItem(at: folder)
    }

    deinit {
        session?.invalidateAndCancel()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Arriving

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        completionHandler((200..<300).contains(status) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let now = Date()
        lock.lock()
        guard !over else { return lock.unlock() }
        if writing == nil || now.timeIntervalSince(pieces.last?.began ?? now) >= Self.span {
            try? writing?.close()
            counter += 1
            let url = folder.appendingPathComponent("\(counter).ts")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            writing = try? FileHandle(forWritingTo: url)
            if writing != nil {
                pieces.append(Piece(index: counter, url: url, began: now, ended: now, size: 0))
                trim(now)
            }
        }
        var kept = false
        if let writing {
            do {
                try writing.write(contentsOf: data)
                kept = true
            } catch {
                // No room left, most likely: the oldest half goes, and this
                // much of the stream with it.
                let drop = min(max(pieces.count / 2, 1), pieces.count - 1)
                for piece in pieces.prefix(drop) { try? FileManager.default.removeItem(at: piece.url) }
                pieces.removeFirst(drop)
            }
        }
        guard kept else {
            // A file that can't be begun, or three lots running that
            // couldn't be written: this isn't keeping anything, and the
            // player starved of it would show nothing at all.
            failures += 1
            guard writing == nil || failures >= 3 else { return lock.unlock() }
            over = true
            let told = onBroken
            onBroken = nil
            onEnd = nil
            lock.broadcast()
            lock.unlock()
            told?()
            return
        }
        failures = 0
        pieces[pieces.count - 1].size += data.count
        pieces[pieces.count - 1].ended = now
        lock.broadcast()
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let wasOver = over
        over = true
        let told = onEnd
        onEnd = nil
        lock.broadcast()
        lock.unlock()
        if !wasOver { told?() }
    }

    /// Lets the oldest go: what's further back than is kept, more than
    /// there's to be room for, or more than the device can spare. Called
    /// with the lock held, as a new file is begun.
    private func trim(_ now: Date) {
        var total = pieces.reduce(Int64(0)) { $0 + Int64($1.size) }
        let spare = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init) ?? .max
        // Always the last half-minute, whatever the room.
        while pieces.count > 4,
              now.timeIntervalSince(pieces[1].began) > reach || total > most || spare < 1_500_000_000 && pieces.count > 8 {
            let gone = pieces.removeFirst()
            total -= Int64(gone.size)
            try? FileManager.default.removeItem(at: gone.url)
            if spare < 1_500_000_000 { break }
        }
    }

    // MARK: Reading

    /// When the oldest of what's kept came, and the newest.
    var kept: (from: Date, to: Date)? {
        lock.lock()
        defer { lock.unlock() }
        guard let first = pieces.first, let last = pieces.last else { return nil }
        return (first.began, last.ended)
    }

    /// The place of what came at a moment: the start of everything kept for
    /// a moment before it, nil when nothing has come yet.
    func place(at moment: Date) -> Place? {
        lock.lock()
        defer { lock.unlock() }
        guard let first = pieces.first else { return nil }
        guard moment > first.began, let piece = pieces.last(where: { $0.began <= moment }) else {
            return Place(piece: first.index, offset: 0)
        }
        // Part-way through the file, by how far through its time.
        let length = piece.ended.timeIntervalSince(piece.began)
        let part = length > 0 ? min(max(moment.timeIntervalSince(piece.began) / length, 0), 1) : 0
        // To a whole packet of the transport stream, as near as can be
        // told: the player finds its own footing all the same.
        return Place(piece: piece.index, offset: Int(Double(piece.size) * part) / 188 * 188)
    }

    /// The place of the newest of it: the broadcast as it comes.
    var end: Place? {
        lock.lock()
        defer { lock.unlock() }
        return pieces.last.map { Place(piece: $0.index, offset: $0.size) }
    }

    /// The next of what's kept from a place, moving the place past it. At
    /// the newest end it waits for more to come, a quarter of a second at a
    /// time so that `stopped` is heard. Nil when there's no more to be had:
    /// the buffer is done with, or the caller is.
    func read(from place: inout Place, upTo count: Int, stopped: () -> Bool) -> Data? {
        while true {
            lock.lock()
            if over && pieces.isEmpty { lock.unlock(); return nil }
            guard let first = pieces.first else {
                // Nothing has come yet.
                lock.wait(until: Date().addingTimeInterval(0.25))
                lock.unlock()
                if stopped() { return nil }
                continue
            }
            // Fallen off the old end while it waited (held on a pause
            // longer than is kept): on from the oldest there is.
            if place.piece < first.index { place = Place(piece: first.index, offset: 0) }
            guard let at = pieces.firstIndex(where: { $0.index == place.piece }) else {
                // Past the newest: the file it was sent on to hasn't been
                // begun yet.
                if over { lock.unlock(); return nil }
                lock.wait(until: Date().addingTimeInterval(0.25))
                lock.unlock()
                if stopped() { return nil }
                continue
            }
            let piece = pieces[at]
            if place.offset < piece.size {
                let want = min(count, piece.size - place.offset)
                lock.unlock()
                guard let file = try? FileHandle(forReadingFrom: piece.url) else {
                    // Let go between the looking and the reading.
                    place = Place(piece: piece.index + 1, offset: 0)
                    continue
                }
                defer { try? file.close() }
                try? file.seek(toOffset: UInt64(place.offset))
                guard let data = try? file.read(upToCount: want), !data.isEmpty else {
                    place = Place(piece: piece.index + 1, offset: 0)
                    continue
                }
                place.offset += data.count
                return data
            }
            if at < pieces.count - 1 {
                place = Place(piece: pieces[at + 1].index, offset: 0)
                lock.unlock()
                continue
            }
            if over { lock.unlock(); return nil }
            lock.wait(until: Date().addingTimeInterval(0.25))
            lock.unlock()
            if stopped() { return nil }
        }
    }
}

/// The player's end of a `LiveBuffer`: a pipe, written into from a place in
/// what's kept and read by the player as if it were the broadcast. It's
/// written as fast as the player takes it, which is as fast as it plays, and
/// at the newest end as fast as the broadcast comes. To show another moment
/// a new one is made from that place and the player given it.
///
/// Or the player's end of a recording the server is still making
/// (`LiveRecording`), which is read the same way from further back than
/// anything kept here.
final class LiveFeed: @unchecked Sendable {
    /// What the player is told to play.
    let url: URL

    /// The next of what's fed, nil when there's no more of it.
    private let next: LiveRecording.Reader
    private let reading: Int32
    private let writing: Int32
    private let lock = NSLock()
    private var cancelled = false

    convenience init?(_ buffer: LiveBuffer, from place: LiveBuffer.Place?) {
        // From the oldest, where no place was given and none can be yet.
        var place = place ?? LiveBuffer.Place(piece: 0, offset: 0)
        self.init(reading: { stopped in buffer.read(from: &place, upTo: 128 * 1024, stopped: stopped) })
    }

    init?(reading next: @escaping LiveRecording.Reader) {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0, let url = URL(string: "fd://\(ends[0])") else { return nil }
        reading = ends[0]
        writing = ends[1]
        // The player gone from the other end is no cause to be killed.
        _ = fcntl(writing, F_SETNOSIGPIPE, 1)
        _ = fcntl(writing, F_SETFL, fcntl(writing, F_GETFL) | O_NONBLOCK)
        self.next = next
        self.url = url
        let thread = Thread { [self] in run() }
        thread.name = "LiveFeed"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// No more is written. The pipe is kept a few seconds longer: the
    /// player may not have taken it up yet, or be only now letting it go,
    /// and a pipe closed and its number given to the next would have the
    /// one mistaken for the other.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func run() {
        // A pool a turn: the thread has none of its own until it ends, and
        // without one every piece read stayed in memory for as long as the
        // channel was watched, megabytes a second.
        var more = true
        while more, !isCancelled {
            more = autoreleasepool {
                guard let data = next({ self.isCancelled }) else { return false }
                var sent = 0
                while sent < data.count {
                    if isCancelled { return false }
                    let wrote = data.withUnsafeBytes { bytes in
                        write(writing, bytes.baseAddress!.advanced(by: sent), data.count - sent)
                    }
                    if wrote > 0 {
                        sent += wrote
                    } else if wrote < 0, errno == EAGAIN || errno == EINTR {
                        // Full: the player takes it at the speed it plays.
                        var waiting = pollfd(fd: writing, events: Int16(POLLOUT), revents: 0)
                        poll(&waiting, 1, 200)
                    } else {
                        return false
                    }
                }
                return true
            }
        }
        let (reading, writing) = (reading, writing)
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            close(writing)
            close(reading)
        }
    }
}
