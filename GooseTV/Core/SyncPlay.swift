import Foundation

/// The server's own connection to this device, over which it says what's
/// happening without being asked: a group's members joining and leaving,
/// and when to play, pause or move. Kept open while this device is in a
/// group watching together.
@MainActor
final class ServerSocket {
    /// A message from the server: its type, and what came with it.
    var onMessage: ((String, Any?) -> Void)?
    /// The connection dropped, not closed from here.
    var onDrop: (() -> Void)?
    private(set) var isOpen = false
    private var task: URLSessionWebSocketTask?
    private var keepAlive: Task<Void, Never>?
    /// Waiting on the first word from the server, which says the
    /// connection is the session's.
    private var opening: CheckedContinuation<Void, Never>?

    /// Opens it, and waits (a few seconds at most) for the server to answer.
    func open(_ request: URLRequest) async {
        close()
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        receive(on: task)
        await withCheckedContinuation { waiting in
            opening = waiting
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finishOpening()
            }
        }
        // Open only if it's still this connection: one that failed (refused,
        // no network) has let go of its task by now.
        isOpen = self.task === task
    }

    func close() {
        keepAlive?.cancel()
        keepAlive = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isOpen = false
        finishOpening()
    }

    private func finishOpening() {
        opening?.resume()
        opening = nil
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.task === task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.read(text) }
                    self.receive(on: task)
                case .failure:
                    self.task = nil
                    self.isOpen = false
                    self.keepAlive?.cancel()
                    self.finishOpening()
                    self.onDrop?()
                }
            }
        }
    }

    private func read(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["MessageType"] as? String else { return }
        finishOpening()
        if type == "ForceKeepAlive" {
            // Told how often it wants to hear: twice as often as that.
            let every = max((message["Data"] as? Double) ?? 60, 10) / 2
            keepAlive?.cancel()
            keepAlive = Task { [weak self] in
                while !Task.isCancelled {
                    self?.send("KeepAlive")
                    try? await Task.sleep(for: .seconds(every))
                }
            }
            return
        }
        if type == "KeepAlive" { return }
        onMessage?(type, message["Data"])
    }

    func send(_ type: String) {
        task?.send(.string(#"{"MessageType":"\#(type)"}"#)) { _ in }
    }
}

/// Watching together, as Jellyfin has it (SyncPlay): a group of the server's
/// accounts and devices, each playing the same film, which the server keeps
/// in step. What anyone in it does (play, pause, a move along the film) is
/// asked of the server, which tells every member, this one too, to do it at
/// a moment by its clock. So nothing is done here on a press: it's done when
/// the server says. This keeps the group, its queue, and this device's
/// clock set by the server's; a player taking part (`SyncPlayDriver`) does
/// the playing.
@MainActor
final class SyncPlay: ObservableObject {
    /// One for the app, as there's one account signed in and one film
    /// playing at a time.
    static let shared = SyncPlay()

    /// One film in the group's queue, as the group knows it.
    struct Entry: Equatable {
        let itemId: String
        let playlistItemId: String
    }

    /// What the group is to play: its films, and which one now, from where.
    struct Queue: Equatable {
        let entries: [Entry]
        let index: Int
        let startTicks: Int64
        let isPlaying: Bool
        let reason: String

        var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }
    }

    /// What the server tells every member to do, and when.
    struct Command: Equatable {
        /// Unpause, Pause, Seek or Stop.
        let name: String
        let playlistItemId: String
        /// By the server's clock.
        let when: Date
        let positionTicks: Int64

        var seconds: Double { Double(positionTicks) / 10_000_000 }
    }

    @Published private(set) var access: SyncPlayAccess = .none
    /// The group this device is in, where it's in one.
    @Published private(set) var group: SyncPlayGroupInfo?
    /// Idle, Waiting, Paused or Playing.
    @Published private(set) var state = "Idle"
    @Published private(set) var queue: Queue?
    /// The last thing the server said to do.
    @Published private(set) var command: Command?
    /// A film the group has started that no player here is showing: the
    /// app opens one for it.
    @Published var launch: String?
    /// What went wrong, to be said.
    @Published var problem: String?

    /// The player taking part, while one is.
    weak var driver: SyncPlayDriver?
    /// How many film players are open: with none, a film the group starts
    /// is opened for it (`launch`).
    var playersOpen = 0

    private var client: (any MediaServer)?
    private var link: ServerLink { .shared }
    /// The server's clock less this device's.
    private var offset: TimeInterval = 0
    private var samples: [(offset: TimeInterval, delay: TimeInterval)] = []
    private var clocking: Task<Void, Never>?
    /// Trying the connection again after it dropped.
    private var reconnecting = false

    var isInGroup: Bool { group != nil }

    /// The film the group is on, while it's on one.
    var playingItemId: String? { state == "Idle" ? nil : queue?.current?.itemId }

    /// Whether the group's queue has more after what's playing.
    var hasNext: Bool { queue.map { $0.index + 1 < $0.entries.count } ?? false }

    private init() {
        ServerLink.shared.listen("together", message: { [weak self] type, data in self?.read(type, data) },
                                 dropped: { [weak self] in self?.dropped() })
    }

    /// The account signed in: what it may do here.
    func use(_ client: any MediaServer) async {
        self.client = client
        let may = await client.syncPlayAccess()
        if self.client === client { access = may }
        #if DEBUG
        debugGroup()
        #endif
    }

    #if DEBUG
    /// GOOSETV_TOGETHER=create starts a group once signed in; =join joins
    /// the first the server lists, once there is one (to test two
    /// simulators in step).
    private func debugGroup() {
        let asked = ProcessInfo.processInfo.environment["GOOSETV_TOGETHER"]
        guard asked != nil, !debugAsked else { return }
        debugAsked = true
        Task {
            if asked == "create" {
                try? await Task.sleep(for: .seconds(2))
                if !isInGroup { await create(named: Self.title) }
            } else if asked == "join" {
                while !isInGroup {
                    if let first = await groups().first { await join(first.groupId) }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }
    private var debugAsked = false
    #endif

    /// Signed out, or another server: out of any group, and nothing allowed.
    func forget() {
        if group != nil, let client { Task { try? await client.syncPlay("Leave", nil) } }
        end()
        client = nil
        access = .none
    }

    // MARK: The server's clock

    /// Now, by the server's clock.
    var serverNow: Date { Date().addingTimeInterval(offset) }

    /// A moment the server named, by this device's clock.
    func local(_ serverTime: Date) -> Date { serverTime.addingTimeInterval(-offset) }

    /// Measured a few times as the group is joined and then every half
    /// minute, as the time a request takes there and back: the quickest
    /// round trip is the truest.
    private func keepClock() {
        clocking?.cancel()
        clocking = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                await self?.measureClock()
                count += 1
                try? await Task.sleep(for: .seconds(count < 5 ? 1 : 30))
            }
        }
    }

    private func measureClock() async {
        guard let client else { return }
        let sent = Date()
        guard let (received, answered) = try? await client.serverClock() else { return }
        let back = Date()
        let offset = (received.timeIntervalSince(sent) + answered.timeIntervalSince(back)) / 2
        let delay = back.timeIntervalSince(sent) - answered.timeIntervalSince(received)
        samples.append((offset, delay))
        if samples.count > 8 { samples.removeFirst() }
        if let best = samples.min(by: { $0.delay < $1.delay }) { self.offset = best.offset }
        // The server times what it tells each member by how long it takes to reach them.
        try? await client.syncPlay("Ping", ["Ping": Int((delay * 1000).rounded())])
    }

    // MARK: Groups

    func groups() async -> [SyncPlayGroupInfo] {
        (try? await client?.syncPlayGroups()) ?? []
    }

    /// Starts a group, with this device in it.
    func create(named name: String) async {
        guard await connect(), let client else { return }
        do {
            try await client.syncPlay("New", ["GroupName": name])
        } catch {
            problem = String(localized: "Couldn't start a group.", comment: "Watch Together: the server refused or didn't answer when asked to start a group")
            letGoUnlessInGroup()
        }
    }

    func join(_ groupId: String) async {
        guard await connect(), let client else { return }
        do {
            try await client.syncPlay("Join", ["GroupId": groupId])
        } catch {
            problem = Self.joinFailed
            letGoUnlessInGroup()
        }
    }

    func leave() async {
        guard group != nil, let client else { return }
        try? await client.syncPlay("Leave", nil)
        end()
    }

    /// The server's connection open before anything is asked that it will
    /// answer over it. The clock is set once in a group: a ping before then
    /// is answered that this device is in none, over the same connection.
    private func connect() async -> Bool {
        guard client != nil else { return false }
        let open = await link.hold("together", inBackground: true)
        if !open { letGoUnlessInGroup() }
        return open
    }

    /// Asked for for a group that didn't come of it: not wanted open for one.
    private func letGoUnlessInGroup() {
        if group == nil { link.release("together") }
    }

    private func end() {
        clocking?.cancel()
        clocking = nil
        link.release("together")
        group = nil
        queue = nil
        command = nil
        state = "Idle"
        launch = nil
        driver?.groupEnded()
    }

    /// The connection dropped with the group still on: the link tries it
    /// again; not back within a few seconds, out of the group.
    private func dropped() {
        guard !reconnecting, group != nil else { return }
        reconnecting = true
        Task {
            try? await Task.sleep(for: .seconds(6))
            reconnecting = false
            if group != nil, !link.isOpen { end() }
        }
    }

    // MARK: Asking the group

    /// What's to be played: for everyone, from there. An episode brings the
    /// ones after it where the account plays on, so the group goes on to the
    /// next together.
    func play(_ item: BaseItem, from ticks: Int64, onward: Bool) async {
        guard let client else { return }
        var queue = [item.id]
        if item.isEpisode, onward { queue += await client.episodes(after: item, limit: 20).map(\.id) }
        try? await client.syncPlay("SetNewQueue", ["PlayingQueue": queue, "PlayingItemPosition": 0, "StartPositionTicks": ticks])
    }

    /// Where the group is in a film of its queue, by the last word from the
    /// server: for a player opening on it, or built again part-way.
    func position(of itemId: String) -> (seconds: Double, playing: Bool)? {
        // Stopped (it ended): opened again, it's a new start.
        guard state != "Idle", let queue, let current = queue.current, current.itemId == itemId else { return nil }
        guard let command, command.playlistItemId == current.playlistItemId else {
            return (Double(queue.startTicks) / 10_000_000, queue.isPlaying)
        }
        guard command.name == "Unpause" else { return (command.seconds, false) }
        return (command.seconds + max(Date().timeIntervalSince(local(command.when)), 0), true)
    }

    func ask(_ request: String, _ body: [String: Any]? = nil) {
        guard let client else { return }
        Task { try? await client.syncPlay(request, body) }
    }

    /// This device's player, loading or ready, at where it is: the server
    /// holds the group until every member is ready.
    func report(ready: Bool, at seconds: Double, playing: Bool, item playlistItemId: String) {
        ask(ready ? "Ready" : "Buffering", [
            "When": ServerTime.write(serverNow),
            "PositionTicks": Int64((max(seconds, 0) * 10_000_000).rounded()),
            "IsPlaying": playing,
            "PlaylistItemId": playlistItemId,
        ])
    }

    // MARK: What the server says

    private func read(_ type: String, _ data: Any?) {
        guard let data = data as? [String: Any] else { return }
        switch type {
        case "SyncPlayGroupUpdate": update(data)
        case "SyncPlayCommand": commanded(data)
        default: break
        }
    }

    private func update(_ message: [String: Any]) {
        let payload = message["Data"]
        switch message["Type"] as? String {
        case "GroupJoined":
            if let info = payload as? [String: Any] {
                if group == nil { keepClock() }
                group = Self.group(from: info)
                state = (info["State"] as? String) ?? "Idle"
            }
        case "UserJoined", "UserLeft":
            // Who's in it, as the server now lists it.
            Task { [weak self] in
                guard let self, let id = self.group?.groupId,
                      let listed = await self.groups().first(where: { $0.groupId == id }) else { return }
                self.group = listed
            }
        case "GroupLeft", "NotInGroup":
            // Said of a request made out of a group too: nothing to end then,
            // and the connection is wanted for the joining under way.
            if group != nil { end() }
        case "GroupDoesNotExist":
            // Gone before it was joined.
            if group == nil { problem = Self.joinFailed }
            end()
        case "LibraryAccessDenied":
            problem = String(localized: "Someone in the group can't see what was chosen.", comment: "Watch Together: the server refused a film because a member of the group has no access to it")
        case "StateUpdate":
            if let info = payload as? [String: Any], let now = info["State"] as? String { state = now }
        case "PlayQueue":
            guard let info = payload as? [String: Any] else { return }
            let entries = (info["Playlist"] as? [[String: Any]] ?? []).compactMap { entry -> Entry? in
                guard let item = entry["ItemId"] as? String, let id = entry["PlaylistItemId"] as? String else { return nil }
                return Entry(itemId: item, playlistItemId: id)
            }
            let queue = Queue(entries: entries, index: info["PlayingItemIndex"] as? Int ?? 0,
                              startTicks: (info["StartPositionTicks"] as? NSNumber)?.int64Value ?? 0,
                              isPlaying: info["IsPlaying"] as? Bool ?? false,
                              reason: info["Reason"] as? String ?? "")
            self.queue = queue
            // Said just before the group's state: it's under way now.
            if state == "Idle", queue.current != nil { state = "Waiting" }
            if let driver {
                driver.queueChanged(queue)
            } else if playersOpen == 0, let current = queue.current {
                // Started by someone else, with nothing playing here yet.
                launch = current.itemId
            }
        default:
            break
        }
    }

    private func commanded(_ data: [String: Any]) {
        guard let name = data["Command"] as? String, let when = ServerTime.parse(data["When"] as? String) else { return }
        let command = Command(name: name, playlistItemId: data["PlaylistItemId"] as? String ?? "",
                              when: when, positionTicks: (data["PositionTicks"] as? NSNumber)?.int64Value ?? 0)
        self.command = command
        driver?.apply(command)
    }

    // MARK: What's said of it

    static var joinFailed: String {
        String(localized: "Couldn't join the group.", comment: "Watch Together: the server refused or didn't answer when asked to join a group")
    }

    static var title: String {
        String(localized: "Watch Together", comment: "Menu section and player menu: watching the same film in step with other people, each on their own device (Jellyfin's SyncPlay)")
    }

    static var startTitle: String {
        String(localized: "Start a Group", comment: "Watch Together: starts a group others can join to watch in step")
    }

    static var leaveTitle: String {
        String(localized: "Leave Group", comment: "Watch Together: leaves the group; the film carries on here alone")
    }

    static var noGroupsTitle: String {
        String(localized: "No groups to join", comment: "Watch Together: the server has no groups at the moment")
    }

    /// "Sam's Group".
    static func newGroupName(for user: String?) -> String {
        guard let user, !user.isEmpty else { return title }
        return String(localized: "\(user)'s Group", comment: "Watch Together: the name given to a new group; the placeholder is the name of the person who started it")
    }

    static func name(of group: SyncPlayGroupInfo) -> String {
        group.groupName.flatMap { $0.isEmpty ? nil : $0 } ?? title
    }

    /// "Join Sam's Group".
    static func joinTitle(_ group: SyncPlayGroupInfo) -> String {
        String(localized: "Join \(name(of: group))", comment: "Watch Together: joins a group; the placeholder is its name, like Sam's Group")
    }

    /// Who's in it: "Sam, Dave".
    static func members(of group: SyncPlayGroupInfo) -> String? {
        guard let names = group.participants, !names.isEmpty else { return nil }
        return names.formatted(.list(type: .and, width: .narrow))
    }

    private static func group(from info: [String: Any]) -> SyncPlayGroupInfo? {
        guard let id = info["GroupId"] as? String else { return nil }
        return SyncPlayGroupInfo(groupId: id, groupName: info["GroupName"] as? String,
                                 state: info["State"] as? String, participants: info["Participants"] as? [String])
    }
}
