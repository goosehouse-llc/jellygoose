import Foundation

/// Settings that follow the viewer from device to device through iCloud's
/// key-value store: what they watch and how they've arranged it. What belongs
/// to the device itself (its colours, its picture, sound and network, its
/// players and downloads, Live TV's switches, who's signed in on it) stays
/// where it is, and so can its pinned views (`sharesPins`).
///
/// The settings stay where they always were, in `UserDefaults`; this copies
/// them out as they change and copies in what other devices change.
@MainActor
final class SettingsSync: ObservableObject {
    static let shared = SettingsSync()
    /// On unless turned off (Settings → iCloud Sync). Kept on the device.
    static let switchKey = "goosetv.sync.iCloud"
    /// Set once this device's settings have been put together with iCloud's.
    private static let joinedKey = "goosetv.sync.joined"
    /// Posted after iCloud's changes are written here; `userInfo["keys"]`
    /// names them, for what holds a setting in memory to read it again.
    static let changed = Notification.Name("goosetv.sync.changed")
    /// Its name in Settings.
    static var title: String { String(localized: "iCloud Sync", comment: "Settings tile and page: settings shared between devices through iCloud") }

    @Published var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            defaults.set(isOn, forKey: Self.switchKey)
            if isOn {
                start()
            } else {
                stop()
                // Turned on again later, it's joined again: its settings and
                // iCloud's put together, nothing of either lost.
                defaults.removeObject(forKey: Self.joinedKey)
            }
        }
    }

    /// Pinned views shared as well, unless turned off on this device
    /// (Settings → iCloud Sync). Kept on the device.
    static let pinsKey = "goosetv.sync.pins"

    @Published var sharesPins: Bool {
        didSet {
            guard sharesPins != oldValue else { return }
            defaults.set(sharesPins, forKey: Self.pinsKey)
            guard !observers.isEmpty else { return }
            if sharesPins {
                // Back on: this device's pins and iCloud's put together, as
                // when a device joins, so neither's are lost.
                take(store.dictionaryRepresentation.keys.filter(Self.isPinned), joining: true)
                send()
            } else {
                // No longer counted as sent, or the next send would take
                // them out of iCloud, from every other device too.
                for key in sent.keys where Self.isPinned(key) { sent[key] = nil }
            }
        }
    }

    // MARK: What's shared

    /// These keys... (not the colour schemes: each device keeps its own)
    private static let keys: Set<String> = [
        SubtitleAppearance.sizeKey, SubtitleAppearance.tintKey,
        SubtitleAppearance.backingKey, SubtitleAppearance.placeKey,
        PlaybackPreferences.autoSkipIntrosKey, PlaybackPreferences.autoSkipCreditsKey,
        PlaybackPreferences.autoSkipRecapsKey, PlaybackPreferences.autoSkipCommercialsKey,
        PlaybackPreferences.remembersTracksKey, TrackMemory.key, AudioSync.key, ThemeMusic.key,
        MusicPlayer.bookSpeedKey, AppState.homeOrderKey, AppState.homeHiddenKey,
    ]
    /// ...and these, each account's own (its id follows).
    private static let accountPrefixes = [
        "goosetv.pins.", "goosetv.menuOrder.", "goosetv.libraryOrder.",
        "goosetv.libraryFilters.", "goosetv.hiddenNextUp.", "goosetv.tabBar.",
    ]

    static func shares(_ key: String) -> Bool {
        if isPinned(key) { return sharingPins }
        return keys.contains(key) || accountPrefixes.contains { key.hasPrefix($0) }
    }

    /// Each account's pins, and the phone's tab bar, which can hold them.
    private static func isPinned(_ key: String) -> Bool {
        key.hasPrefix("goosetv.pins.") || key.hasPrefix("goosetv.tabBar.")
    }

    private static var sharingPins: Bool {
        UserDefaults.standard.object(forKey: pinsKey) as? Bool ?? true
    }

    /// How a setting from elsewhere meets this device's own.
    private enum Meeting {
        /// The other device's stands (a choice, an order).
        case replace
        /// Pins: put together when a device joins, so neither's are lost;
        /// after that the latest list stands, so one removed stays removed.
        case pins
        /// Lists that only grow (until the oldest are let go), put together
        /// every time: each show's tracks, the episodes taken off Next Up.
        case grows(field: String?, most: Int)
        /// One entry for each title or library, put together entry by entry,
        /// the other device's winning where both have one.
        case entries
    }

    private static func meeting(for key: String) -> Meeting {
        if key == TrackMemory.key { return .grows(field: "show", most: TrackMemory.most) }
        if key.hasPrefix("goosetv.hiddenNextUp.") { return .grows(field: nil, most: AppState.mostHiddenNextUp) }
        if key.hasPrefix("goosetv.pins.") { return .pins }
        if key == AudioSync.key || key.hasPrefix("goosetv.libraryFilters.") { return .entries }
        return .replace
    }

    // MARK: Running

    private let defaults = UserDefaults.standard
    private let store = NSUbiquitousKeyValueStore.default
    /// Each shared setting as iCloud last had it, as far as this device
    /// knows: a setting here that's different has changed here, to be sent.
    private var sent: [String: Any] = [:]
    /// Joining: iCloud's copy given a moment to arrive before this device's
    /// is sent, so the first device's settings aren't swept away by the next.
    private var joining = false
    /// For a while after joining, pins coming in are put together with
    /// these rather than replacing them: two devices joining at once.
    private var settlesUntil = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var joinWait: Task<Void, Never>?
    private var sendSoon: Task<Void, Never>?

    private init() {
        isOn = UserDefaults.standard.object(forKey: Self.switchKey) as? Bool ?? true
        sharesPins = Self.sharingPins
    }

    /// Whether iCloud is reached at all: not in a simulator, whose runs
    /// would otherwise carry settings from one test into the next (iCloud's
    /// copy outlives the app), unless GOOSETV_SYNC=1 asks for it. Nor in a
    /// Mac's debug build, which runs on the developer's own Mac and iCloud:
    /// a test's settings and pins would reach their TVs and phone.
    private var reachable: Bool {
        #if targetEnvironment(simulator) || (os(macOS) && DEBUG)
        ProcessInfo.processInfo.environment["GOOSETV_SYNC"] == "1"
        #else
        true
        #endif
    }

    /// At launch: from now on, settings go out as they change and come in
    /// as other devices change them.
    func start() {
        guard isOn, reachable, observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                            object: store, queue: .main) { [weak self] note in
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated { self?.arrived(keys, reason: reason) }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changedHere() }
        })
        store.synchronize()

        if defaults.bool(forKey: Self.joinedKey) {
            // What came in while the app was closed, then what changed here
            // and never went (a setting iCloud hasn't heard of).
            take(Array(store.dictionaryRepresentation.keys), joining: false)
            send()
        } else {
            joining = true
            joinWait?.cancel()
            joinWait = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                self?.join()
            }
        }
    }

    private func stop() {
        joinWait?.cancel()
        joinWait = nil
        sendSoon?.cancel()
        sendSoon = nil
        joining = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        sent = [:]
    }

    /// Joining over: iCloud's settings taken (put together with these where
    /// they meet), then this device's own sent.
    private func join() {
        joining = false
        take(Array(store.dictionaryRepresentation.keys), joining: true)
        defaults.set(true, forKey: Self.joinedKey)
        settlesUntil = Date().addingTimeInterval(10 * 60)
        send()
    }

    /// Back in front, or about to leave: what's waiting both ways.
    func refresh() {
        guard !observers.isEmpty else { return }
        store.synchronize()
    }

    func flush() {
        guard !observers.isEmpty, !joining else { return }
        sendSoon?.cancel()
        sendSoon = nil
        send()
        store.synchronize()
    }

    // MARK: In

    private func arrived(_ keys: [String], reason: Int?) {
        switch reason {
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            return
        case NSUbiquitousKeyValueStoreAccountChange, NSUbiquitousKeyValueStoreInitialSyncChange:
            // Another iCloud account's settings, or the first from iCloud:
            // put together with these, as joining does.
            take(keys, joining: true)
        default:
            take(keys, joining: joining || Date() < settlesUntil)
        }
        if !joining { send() }
    }

    /// iCloud's value for each of these written here, where it's different.
    private func take(_ keys: [String], joining: Bool) {
        var changed: [String] = []
        for key in keys where Self.shares(key) {
            let theirs = store.object(forKey: key)
            sent[key] = theirs
            let ours = defaults.object(forKey: key)
            let value: Any? = switch (ours, theirs) {
            case (nil, _): theirs
            case (let ours?, nil): joining ? ours : nil
            case (let ours?, let theirs?): Self.meet(ours, theirs, key: key, joining: joining)
            }
            if !Self.same(value, ours) {
                defaults.set(value, forKey: key)
                changed.append(key)
            }
        }
        if !changed.isEmpty {
            NotificationCenter.default.post(name: Self.changed, object: self, userInfo: ["keys": changed])
        }
    }

    /// This device's setting and another's, as one.
    private static func meet(_ ours: Any, _ theirs: Any, key: String, joining: Bool) -> Any {
        // Home's rows, while pins stay here: the other device can't know
        // this one's pinned rows, so they keep their places from here.
        if !sharingPins, key == AppState.homeOrderKey || key == AppState.homeHiddenKey,
           let mine = ours as? [String], let others = theirs as? [String] {
            return keepingOwnPins(mine, in: others, ordered: key == AppState.homeOrderKey)
        }
        switch meeting(for: key) {
        case .replace:
            return theirs
        case .pins:
            guard joining, let mine = json(ours) as? [[String: Any]], let others = json(theirs) as? [[String: Any]] else { return theirs }
            // The same view pinned on both (by id, or the same library and
            // filters pinned separately) is kept once, as the other has it.
            let extra = mine.filter { pin in
                !others.contains { other in
                    same(other["id"], pin["id"])
                        || (same(other["libraryId"], pin["libraryId"]) && same(other["filters"], pin["filters"]))
                }
            }
            return data(others + extra) ?? theirs
        case .grows(let field, let most):
            if let mine = ours as? [String], let others = theirs as? [String] {
                return Array((mine.filter { !others.contains($0) } + others).suffix(most))
            }
            guard let field, let mine = json(ours) as? [[String: Any]], let others = json(theirs) as? [[String: Any]] else { return theirs }
            // Newest last: what only this device has goes before theirs.
            let extra = mine.filter { entry in !others.contains { same($0[field], entry[field]) } }
            return data(Array((extra + others).suffix(most))) ?? theirs
        case .entries:
            if let mine = ours as? [String: Any], let others = theirs as? [String: Any] {
                return mine.merging(others) { _, theirs in theirs }
            }
            guard let mine = json(ours) as? [String: Any], let others = json(theirs) as? [String: Any] else { return theirs }
            return data(mine.merging(others) { _, theirs in theirs }) ?? theirs
        }
    }

    // MARK: Out

    /// A setting changed here: sent a second later, with whatever else
    /// changes in that second (and not put off for as long as changes keep
    /// coming).
    private func changedHere() {
        guard !joining, sendSoon == nil else { return }
        sendSoon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.sendSoon = nil
            self.send()
        }
    }

    /// Each shared setting that's different from iCloud's, sent.
    private func send() {
        guard !observers.isEmpty, !joining else { return }
        let ours = (defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:])
            .filter { Self.shares($0.key) }
        for (key, value) in ours where !Self.same(value, sent[key]) {
            store.set(value, forKey: key)
            sent[key] = value
        }
        for key in sent.keys where ours[key] == nil {
            store.removeObject(forKey: key)
            sent[key] = nil
        }
    }

    // MARK: Helpers

    /// Home's rows (in order, or the hidden ones) as another device has
    /// them, with this device's own pinned rows put back: in order, each
    /// after the row it followed here, or last if it came after them all.
    static func keepingOwnPins(_ mine: [String], in theirs: [String], ordered: Bool) -> [String] {
        let own = ownPinRows()
        var rows = theirs.filter { !own.contains($0) }
        for (index, row) in mine.enumerated() where own.contains(row) {
            let wasLast = !mine[(index + 1)...].contains { rows.contains($0) }
            guard ordered, !wasLast else { rows.append(row); continue }
            let before = mine[..<index].last { rows.contains($0) }
            rows.insert(row, at: before.flatMap { rows.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
        return rows
    }

    /// The Home rows of every view pinned on this device, whoever's.
    private static func ownPinRows() -> Set<String> {
        let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        var rows: Set<String> = []
        for (key, value) in saved where key.hasPrefix("goosetv.pins.") {
            guard let data = value as? Data, let pins = try? JSONDecoder().decode([PinnedFilter].self, from: data) else { continue }
            rows.formUnion(pins.map { HomeLayout.pinned($0.id) })
        }
        return rows
    }

    /// Alike in what they say: JSON by what's in it, since the same
    /// settings can be written out in a different order.
    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a as Data, let b as Data):
            if a == b { return true }
            guard let a = json(a), let b = json(b) else { return false }
            return (a as AnyObject).isEqual(b as AnyObject)
        case (let a?, let b?): return (a as AnyObject).isEqual(b as AnyObject)
        default: return false
        }
    }

    /// A setting the app keeps as JSON, opened up.
    private static func json(_ value: Any) -> Any? {
        guard let data = value as? Data else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func data(_ object: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }
}
