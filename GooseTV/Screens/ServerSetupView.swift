import SwiftUI

struct ServerSetupView: View {
    @EnvironmentObject var app: AppState
    @State private var address = ""
    @State private var checking = false
    @State private var errorMessage: String?
    @State private var saved: [SavedServer] = SavedServers.all()
    /// Servers that answered a search of the local network, already checked
    /// to be reachable. Every one, including those under Recent: forgetting
    /// one of those lists it here at once, with no second search of the
    /// network running over the first.
    @State private var found: [NearbyServer] = []
    @State private var searching = false
    @Environment(\.isNarrow) private var narrow

    struct NearbyServer: Identifiable {
        let id: String
        let url: URL
        let flavor: ServerFlavor
        let name: String
    }

    var body: some View {
        page.scrollsVertically(narrow)
    }

    private var page: some View {
        VStack(spacing: narrow ? 36 : 56) {
            VStack(spacing: 22) {
                BrandTile(size: narrow ? 72 : 104)
                GooseWordmark(size: narrow ? 52 : 76)
                Text("Connect to your Jellyfin or Emby server")
                    .font(.app(30, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            // Typing an address on a remote is the worst part of setting this
            // up, so offer every server already known or found nearby first.
            if !saved.isEmpty {
                section(String(localized: "RECENT SERVERS", comment: "Heading above servers used before, shown in capitals")) {
                    ForEach(saved) { server in
                        Button {
                            Task { await reconnect(server) }
                        } label: {
                            ServerCardLabel(name: server.name ?? server.url, flavor: server.flavor,
                                            address: Self.shortAddress(server.url))
                        }
                        .buttonStyle(ServerCardStyle())
                        .contextMenu {
                            Button("Forget This Server", role: .destructive) {
                                SavedServers.forget(server)
                                saved = SavedServers.all()
                            }
                        }
                    }
                }
            }

            if !nearby.isEmpty || searching {
                section(String(localized: "ON YOUR NETWORK", comment: "Heading above servers found on the local network, shown in capitals"),
                        searching: searching) {
                    ForEach(nearby) { server in
                        Button {
                            app.connect(to: server.url, flavor: server.flavor, serverName: server.name)
                        } label: {
                            // Named by family too: one machine can run both, under one name.
                            ServerCardLabel(name: server.name, flavor: server.flavor,
                                            address: Self.shortAddress(server.url.absoluteString))
                        }
                        .buttonStyle(ServerCardStyle())
                    }
                }
            }

            VStack(spacing: 18) {
                Text("OR ENTER AN ADDRESS", comment: "Heading above the server address field, shown in capitals")
                    .font(.app(15, .heavy))
                    .kerning(2)
                    .foregroundStyle(Theme.textSecondary)
                let row = narrow ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(spacing: 18))
                row {
                    // The port can still be left off: 8096 is tried first.
                    TextField("", text: $address, prompt: Text(verbatim: "192.168.1.100:8096"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .onSubmit { if !address.isEmpty, !checking { Task { await connect() } } }
                        .touchField()
                        .frame(maxWidth: narrow ? .infinity : CGFloat(620).scaled)
                    Button {
                        Task { await connect() }
                    } label: {
                        if checking {
                            ProgressView()
                        } else {
                            Text("Connect")
                        }
                    }
                    .buttonStyle(GradientButtonStyle())
                    .disabled(address.isEmpty || checking)
                }
                Text("No port needed: 8096 is tried first. On Tailscale, use the server's 100.x address.")
                    .font(.app(19))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(Theme.palette[1].1)
                        .font(.app(24, .semibold))
                }
            }
            .tvFocusSection()
        }
        .padding(narrow ? 20 : 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await searchNearby() }
    }

    /// What the search found, less the servers already under Recent.
    private var nearby: [NearbyServer] {
        let known = Set(saved.map { $0.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
        return found.filter { !known.contains($0.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
    }

    /// A heading in small capitals over a row of server cards.
    private func section<Cards: View>(_ title: String, searching: Bool = false,
                                      @ViewBuilder cards: () -> Cards) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.app(15, .heavy))
                    .kerning(2)
                    .foregroundStyle(Theme.textSecondary)
                if searching { ProgressView().scaleEffect(0.6) }
            }
            let layout = narrow ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(spacing: 28))
            layout { cards() }
        }
        .tvFocusSection()
    }

    /// "192.168.1.10:8096": the address without the scheme, which says nothing
    /// to anyone choosing a server.
    private static func shortAddress(_ url: String) -> String {
        var text = url
        for scheme in ["http://", "https://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    /// Asks the local network which Jellyfin and Emby servers are on it, and keeps each
    /// at the first address that answers as the same server: the one it
    /// answered from, or the one it advertised, which can be stale. Servers
    /// already under Recent aren't listed twice (see `nearby`).
    private func searchNearby() async {
        searching = true
        defer { searching = false }
        let replies = await ServerDiscovery.search()
        let answered = await withTaskGroup(of: NearbyServer?.self) { group in
            for reply in replies {
                group.addTask {
                    for candidate in reply.candidates {
                        guard let found = await probe(candidate),
                              found.info.id.map({ $0.caseInsensitiveCompare(reply.id) == .orderedSame }) ?? true
                        else { continue }
                        return NearbyServer(id: reply.id, url: found.url, flavor: found.flavor,
                                            name: found.info.serverName ?? reply.name)
                    }
                    return nil
                }
            }
            // Only one program on a machine can answer the search, so a second
            // server beside the one that did stays silent (Jellyfin and Emby on
            // one box, say). Each machine that answered is also tried on the
            // default port.
            let asked = Set(replies.flatMap(\.candidates))
            for host in Set(replies.map(\.host)) {
                guard let url = URL(string: "http://\(host):8096"), !asked.contains(url) else { continue }
                group.addTask {
                    guard let found = await probe(url), let id = found.info.id else { return nil }
                    return NearbyServer(id: id, url: found.url, flavor: found.flavor,
                                        name: found.info.serverName ?? host)
                }
            }
            var servers: [NearbyServer] = []
            for await server in group {
                guard let server, !servers.contains(where: {
                    $0.id.caseInsensitiveCompare(server.id) == .orderedSame
                }) else { continue }
                servers.append(server)
            }
            return servers
        }
        found = answered.sorted { $0.name < $1.name }
    }

    /// A server already known. Still probed, because its address is all that
    /// was kept: what it calls itself and which family it is can both have
    /// changed since, and signing in happens per server either way.
    private func reconnect(_ server: SavedServer) async {
        errorMessage = nil
        checking = true
        defer { checking = false }
        guard let url = URL(string: server.url) else { return }
        if let found = await probe(url) {
            app.connect(to: found.url, flavor: found.flavor, serverName: found.info.serverName)
        } else {
            errorMessage = String(localized: "Couldn't reach \(server.name ?? server.url).", comment: "The placeholder is a server name or address")
        }
    }

    private func connect() async {
        errorMessage = nil
        checking = true
        defer { checking = false }

        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        let candidates = addresses(for: typed)
        guard !candidates.isEmpty else {
            errorMessage = ServerError.invalidURL.errorDescription
            return
        }
        if let found = await firstAnswer(candidates) {
            app.connect(to: found.url, flavor: found.flavor, serverName: found.info.serverName)
            return
        }
        errorMessage = String(localized: "Couldn't reach a Jellyfin or Emby server at that address.")
    }

    /// What to try, in order of preference. A port that was typed is used as
    /// typed. Without one, Jellyfin's own port, 8096, comes first. A name with
    /// dots that isn't a numeric address (jellyfin.example.com) is more likely
    /// behind a reverse proxy, so there TLS on the standard port leads, and a
    /// server that offers it is never reached in the clear just because nobody
    /// typed a port.
    private func addresses(for typed: String) -> [URL] {
        let full = typed.contains("://") ? typed : "http://\(typed)"
        guard var parts = URLComponents(string: full), let host = parts.host, !host.isEmpty,
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme)
        else { return [] }
        // An address copied from a browser carries the page it was on
        // (…/web/#/home.html); only where the server is matters here.
        parts.query = nil
        parts.fragment = nil
        if parts.port != nil { return [parts.url].compactMap { $0 } }

        func at(_ scheme: String, _ port: Int?) -> URL? {
            var url = parts
            url.scheme = scheme
            url.port = port
            return url.url
        }
        // Tailscale's names count as local: its tunnel is encrypted already.
        let local = !host.contains(".") || host.hasSuffix(".local") || host.hasSuffix(".ts.net")
            || host.allSatisfy { $0.isNumber || $0 == "." } || host.contains(":")
        let urls: [URL?]
        switch (typed.contains("://") ? scheme : nil, local) {
        case ("https"?, _): urls = [at("https", nil), at("https", 8920)]
        case ("http"?, _): urls = [at("http", 8096), at("http", nil)]
        case (nil, true): urls = [at("http", 8096), at("https", 8920), at("https", nil), at("http", nil)]
        default: urls = [at("https", nil), at("https", 8920), at("http", 8096), at("http", nil)]
        }
        return urls.compactMap { $0 }
    }

    /// Probes every address at once and takes the most preferred one that
    /// answered, so a wrong guess costs no time before the right one is tried.
    private func firstAnswer(_ urls: [URL]) async -> (url: URL, flavor: ServerFlavor, info: PublicSystemInfo)? {
        let probes = urls.map { url in Task { await probe(url) } }
        defer { probes.forEach { $0.cancel() } }
        for probe in probes {
            if let found = await probe.value { return found }
        }
        return nil
    }

    /// Asks what's listening and which of the two it is. Both answer
    /// /System/Info/Public and name themselves in ProductName; an older Emby that
    /// doesn't is caught by the /emby prefix, which only Emby serves.
    private func probe(_ url: URL, following: Bool = true) async -> (url: URL, flavor: ServerFlavor, info: PublicSystemInfo)? {
        // Capped, because there are several addresses to get through and a
        // machine that isn't listening takes the full request timeout to say so.
        guard let info = await within(.seconds(6), { try? await MediaBrowserClient(baseURL: url).publicInfo() })
        else {
            // Not here, but the address may lead to it.
            guard following, let base = await within(.seconds(6), { await Self.serverBase(reachedFrom: url) })
            else { return nil }
            return await probe(base, following: false)
        }
        if let flavor = ServerFlavor.named(info.productName) { return (url, flavor, info) }

        let embyURL = url.appendingPathComponent("emby")
        if let embyInfo = await within(.seconds(6), {
            try? await MediaBrowserClient(baseURL: embyURL, flavor: .emby).publicInfo()
        }) {
            return (embyURL, .emby, embyInfo)
        }
        return (url, .jellyfin, info)
    }

    /// Where the server is, when the address given only leads to it. A server
    /// kept under a path (demo.jellyfin.org/stable) sends anyone who asks for
    /// the top of the site on to its web pages at <path>/web/, and an address
    /// copied from a browser ends in /web/ itself: either way the server is
    /// whatever comes before /web. Nil when the address leads nowhere new.
    private static func serverBase(reachedFrom url: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let landed = response.url, landed.host?.lowercased() == url.host?.lowercased(),
              var parts = URLComponents(url: landed, resolvingAgainstBaseURL: false),
              let web = parts.path.range(of: "/web", options: [.backwards, .caseInsensitive]),
              parts.path[web.upperBound...].first.map({ $0 == "/" }) ?? true
        else { return nil }
        parts.path = String(parts.path[..<web.lowerBound])
        parts.query = nil
        parts.fragment = nil
        func bare(_ url: URL) -> String { url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        guard let base = parts.url, bare(base) != bare(url) else { return nil }
        return base
    }

    /// Runs the work, or gives up on it. URLSession honours cancellation, so the
    /// request really stops rather than running on unseen.
    private func within<T: Sendable>(_ limit: Duration,
                                     _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
