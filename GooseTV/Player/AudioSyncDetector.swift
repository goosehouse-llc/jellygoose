import Foundation

/// What working out a file's sound against its picture has come to.
enum AudioSyncDetection: Equatable {
    case idle
    /// Listening, and for this many seconds so far.
    case listening(Double)
    /// The sound should move by this many seconds, later being positive.
    case found(Double)
    /// The sound is where it should be.
    case inSync
    /// Listened as long as it's worth, and couldn't tell.
    case unsure
}

/// Works out how far a file's sound is from its picture, with nothing but the
/// file to go on.
///
/// A film's subtitles are timed to its picture, and a line is on screen while
/// it's being said. So over a few minutes, the stretches with speech in them
/// line up with the stretches with a subtitle up, and how far one has to be
/// slid to fit the other best is how far the sound is out. It takes the sound
/// as the player hands it over (everything mixed to one channel), which is
/// rougher than the dialogue channel alone but tells just the same: tried on
/// four episodes of one show, one of them 0.6 s out, it called all four right
/// from most places in them, usually within two minutes.
///
/// It only says so when sure: enough lines, one clear best fit, and the two
/// halves of what it heard agreeing with each other. Otherwise it goes on
/// listening, and after eight minutes gives up.
struct AudioSyncDetector {
    /// The sound's level is kept a fiftieth of a second at a time.
    static let frame = 0.02
    /// The least sound it judges from, how often it looks again, and when it
    /// stops trying, in seconds.
    static let least = 90.0, between = 30.0, most = 480.0

    /// The run of sound being listened to: where it starts, in frames from
    /// the film's start, and each frame's squares summed and counted.
    private var first = 0
    private var sums: [Float] = []
    private var counts: [Int32] = []
    /// The last sample of the buffer before, for the difference across the join.
    private var carried: Float = 0
    /// Every subtitle seen, by when it starts (in thousandths of a second),
    /// with when it ends.
    private var cues: [Int: Double] = [:]
    private var judgedAt = 0.0

    /// How much sound there is to judge from.
    var seconds: Double { Double(sums.count) * Self.frame }

    /// Forgets the sound, to listen afresh. The subtitles are kept: they are
    /// the film's, whenever it's listened to.
    mutating func startOver() {
        first = 0
        sums = []
        counts = []
        carried = 0
        judgedAt = 0
    }

    mutating func note(cues seen: [(start: Double, end: Double)]) {
        for cue in seen where cue.start.isFinite && cue.start >= 0 {
            cues[Int((cue.start * 1000).rounded())] = cue.end
        }
    }

    /// Takes in sound at 48 kHz on one channel, beginning `time` seconds into
    /// the film. Sound from somewhere else in the film (a skip) starts the
    /// run again from there.
    mutating func add(_ samples: UnsafeBufferPointer<Float>, at time: Double) {
        guard time.isFinite, time >= 0, samples.count >= 6 else { return }
        let start = Int(time / Self.frame)
        if sums.isEmpty || start < first - 5 || start > first + sums.count + 100 {
            first = start
            sums = []
            counts = []
            carried = 0
            judgedAt = 0
        }
        // Down to 8 kHz by sixes, then each sample's change from the last:
        // that leaves the voice's band and takes the rumble under it out.
        var index = 0
        var sample = 0
        while index + 6 <= samples.count {
            let mean = (samples[index] + samples[index + 1] + samples[index + 2]
                        + samples[index + 3] + samples[index + 4] + samples[index + 5]) / 6
            let change = mean - carried
            carried = mean
            let at = Int((time + Double(sample) / 8000) / Self.frame) - first
            if at >= 0 {
                if at >= sums.count {
                    sums.append(contentsOf: repeatElement(0, count: at - sums.count + 1))
                    counts.append(contentsOf: repeatElement(0, count: at - counts.count + 1))
                }
                sums[at] += change * change
                counts[at] += 1
            }
            index += 6
            sample += 1
        }
    }

    /// Whether there's enough new sound to be worth judging again.
    mutating func due() -> Bool {
        guard seconds >= Self.least, seconds - judgedAt >= Self.between else { return false }
        judgedAt = seconds
        return true
    }

    /// What there is to judge from, to be judged somewhere other than where
    /// the film is being played from.
    func snapshot() -> Snapshot {
        var levels = [Float](repeating: 0, count: sums.count)
        for index in sums.indices where counts[index] > 0 {
            levels[index] = (sums[index] / Float(counts[index])).squareRoot()
        }
        let from = Double(first) * Self.frame, to = from + seconds
        let within = cues.map { (start: Double($0.key) / 1000, end: $0.value) }
            .filter { $0.start >= from - 5 && $0.start <= to + 5 }
            .sorted { $0.start < $1.start }
        return Snapshot(first: first, levels: levels, cues: within)
    }

    struct Snapshot: Sendable {
        let first: Int
        let levels: [Float]
        let cues: [(start: Double, end: Double)]
    }

    /// How much later the speech is than its subtitles, in seconds (earlier
    /// is negative), or nil when what was heard doesn't settle it.
    static func lag(in heard: Snapshot) -> Double? {
        let count = heard.levels.count
        guard count >= Int(least / frame) else { return nil }
        // A subtitle up, or not, at each frame.
        var shown = [Float](repeating: 0, count: count)
        var lines = 0
        for (index, cue) in heard.cues.enumerated() {
            // Until it's taken down; one still up when last seen is given
            // three seconds, and none runs into the next.
            var end = cue.end.isFinite && cue.end > cue.start ? min(cue.end, cue.start + 8) : cue.start + 3
            if index + 1 < heard.cues.count { end = min(end, heard.cues[index + 1].start) }
            let from = Int(cue.start / frame) - heard.first, to = Int(end / frame) - heard.first
            guard to > 0, from < count else { continue }
            if from >= 0 { lines += 1 }
            for at in max(from, 0)..<min(to, count) { shown[at] = 1 }
        }
        guard lines >= 20, let whole = fit(shown[...], heard.levels[...]) else { return nil }
        let half = count / 2
        guard let one = fit(shown[..<half], heard.levels[..<half]),
              let other = fit(shown[half...], heard.levels[half...]) else { return nil }
        guard whole.strength >= 0.15, whole.clear >= 0.03,
              abs(one.lag - other.lag) <= 0.12, abs(one.lag - whole.lag) <= 0.12 else { return nil }
        return whole.lag
    }

    /// What to move the sound by for that lag: nothing for one too small to
    /// be sure of (a line is up a touch before it's said, in a file that's
    /// right), else the lag undone, to a tenth of a second.
    static func correction(for lag: Double) -> Double {
        let fix = -(lag - 0.04)
        guard abs(fix) >= 0.25 else { return 0 }
        return min(max((fix * 10).rounded() / 10, -2), 2)
    }

    /// The slide, up to two and a half seconds either way, at which speech
    /// and subtitles fit best: how good the fit is there, and how far it
    /// stands above the best anywhere else.
    private static func fit(_ shown: ArraySlice<Float>, _ levels: ArraySlice<Float>)
        -> (lag: Double, strength: Float, clear: Float)? {
        let count = shown.count
        guard count == levels.count, count > 500 else { return nil }
        // Speech, or not: louder than three fifths of what was heard.
        let ranked = levels.sorted()
        let threshold = ranked[Swift.min(count * 6 / 10, count - 1)]
        var voiced = levels.map { $0 > threshold ? Float(1) : 0 }
        var up = Array(shown)
        let voicedMean = voiced.reduce(0, +) / Float(count), upMean = up.reduce(0, +) / Float(count)
        var voicedNorm: Float = 0, upNorm: Float = 0
        for index in 0..<count {
            voiced[index] -= voicedMean
            up[index] -= upMean
            voicedNorm += voiced[index] * voiced[index]
            upNorm += up[index] * up[index]
        }
        guard voicedNorm > 0, upNorm > 0 else { return nil }
        let scale = (voicedNorm * upNorm).squareRoot()
        let reach = 125
        var fits = [Float](repeating: 0, count: reach * 2 + 1)
        for slide in -reach...reach {
            var sum: Float = 0
            let from = Swift.max(0, -slide), to = Swift.min(count, count - slide)
            var index = from
            while index < to {
                sum += up[index] * voiced[index + slide]
                index += 1
            }
            fits[slide + reach] = sum / scale
        }
        guard let best = fits.indices.max(by: { fits[$0] < fits[$1] }) else { return nil }
        // "Anywhere else" is more than three tenths of a second away.
        var rival = -Float.infinity
        for index in fits.indices where abs(index - best) > 15 { rival = Swift.max(rival, fits[index]) }
        return (Double(best - reach) * frame, fits[best], fits[best] - rival)
    }
}
