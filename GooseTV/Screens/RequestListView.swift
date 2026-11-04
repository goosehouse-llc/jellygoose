import SwiftUI

/// The list of requests, as Seerr's own Requests page has it: narrowed by
/// where each stands, in order of asking or of the last change, and each with
/// what may be done about it. Everyone's for someone who may see them, the
/// viewer's own otherwise.
struct RequestListView: View {
    @ObservedObject var requests: Requests
    @Environment(\.isNarrow) private var narrow

    @State private var filter = SeerrClient.RequestFilter.all
    @State private var sort = SeerrClient.RequestSort.added
    @State private var entries: [RequestEntry] = []
    @State private var total = 0
    /// How many of Seerr's requests have been read, and how many of those
    /// aren't listed, their titles not to be found: what's still to come is
    /// counted from where Seerr's list has been read to, not from how many
    /// made it onto this one.
    @State private var taken = 0
    @State private var dropped = 0
    @State private var loaded = false
    @State private var fetching = false
    @State private var problem: String?
    @FocusState private var focus: Spot?

    private enum Spot: Hashable {
        case filter(SeerrClient.RequestFilter)
        case row(Int)
    }

    /// What the list is of: asked again whenever any of it changes.
    private struct Listing: Equatable {
        let filter: SeerrClient.RequestFilter
        let sort: SeerrClient.RequestSort
        let revision: Int
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text(requests.user?.seesAllRequests == true
                     ? String(localized: "All Requests", comment: "Opens the list of everyone's requests")
                     : String(localized: "Your Requests", comment: "Shelf of the titles the viewer has asked for"))
                    .font(.app(26, .bold))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(SeerrClient.RequestFilter.allCases, id: \.self) { kind in
                            Button(Self.name(of: kind)) { filter = kind }
                                .buttonStyle(.chip(active: kind == filter))
                                .focused($focus, equals: .filter(kind))
                        }
                        Button {
                            sort = sort == .added ? .modified : .added
                        } label: {
                            Label(sort == .added ? String(localized: "Most Recent", comment: "Requests in order of when they were made")
                                                 : String(localized: "Last Modified", comment: "Requests in order of when they last changed"),
                                  systemImage: "arrow.up.arrow.down")
                        }
                        .buttonStyle(.chip(active: false))
                        .padding(.leading, 12)
                    }
                    .padding(.vertical, 12)   // room for the focused chip's lift
                    .padding(.horizontal, 6)
                }
                .tvFocusSection()

                if let problem { SettingsNote(problem, tint: Theme.palette[1].0) }

                if let client = requests.client {
                    ForEach(entries) { entry in
                        row(entry, client: client)
                    }
                }
                if !loaded || entries.count < total {
                    // In sight at the foot of what's listed: time for more. A
                    // new one each time the list grows, so one that's still in
                    // sight afterwards asks again.
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .id("more-\(loaded)-\(taken)")
                        .onAppear { Task { await more() } }
                } else if entries.isEmpty, problem == nil {
                    Text("No requests here.", comment: "Shown when the list of requests is empty")
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, 48)
        }
        .pageSides()
        .requestsBackground()
        .task(id: Listing(filter: filter, sort: sort, revision: requests.revision)) { await load() }
    }

    private static func name(of filter: SeerrClient.RequestFilter) -> String {
        switch filter {
        case .all: String(localized: "All", comment: "Filter: every request")
        case .pending: String(localized: "Awaiting Approval", comment: "A requested title that the server's owner hasn't approved yet")
        case .approved: String(localized: "Approved", comment: "Filter: requests that were said yes to")
        case .processing: String(localized: "Requested", comment: "A requested title that is being fetched")
        case .available: String(localized: "In Your Library", comment: "A title that is already in the library")
        case .failed: String(localized: "Failed", comment: "An approved request that couldn't be handed on to be fetched")
        }
    }

    /// One request: through to its title's page, with its buttons beside it
    /// (under it, on a phone).
    private func row(_ entry: RequestEntry, client: SeerrClient) -> some View {
        let request = entry.request
        let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                            : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            NavigationLink(value: entry.title) {
                HStack(spacing: 18) {
                    Color.clear
                        .aspectRatio(2 / 3, contentMode: .fit)
                        .overlay(RemoteImage(url: client.poster(entry.title.posterPath)))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .frame(width: CGFloat(64).scaled)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.title.displayTitle)
                                .font(.app(20, .semibold))
                                .lineLimit(1)
                            if let year = entry.title.year {
                                Text(year)
                                    .font(.app(16))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Text([request.seasonsText, request.byline(naming: requests.user?.seesAllRequests == true)]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.app(16))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    SeerrBadgeView(badge: request.badge, prefix: request.is4k == true ? "4K" : nil)
                }
                .padding(.horizontal, CGFloat(18).scaled)
                .padding(.vertical, CGFloat(12).scaled)
            }
            .buttonStyle(SettingsRowStyle())
            .focused($focus, equals: .row(request.id))

            RequestActionButtons(request: request, requests: requests, settled: { action in
                problem = nil
                await leave(request, after: action)
            }, failed: { problem = $0 })
        }
    }

    /// Focus is on a button of a row that's about to change, and may be about
    /// to go: onto the row itself if it's staying, else its neighbour, else
    /// the filters, before the list is asked for again.
    private func leave(_ request: SeerrRequest, after action: SeerrRequest.Action) async {
        let going = action == .cancel || action == .delete || filter != .all
        if !going {
            focus = .row(request.id)
        } else if let at = entries.firstIndex(where: { $0.id == request.id }) {
            let neighbour = entries.indices.contains(at + 1) ? entries[at + 1] : at > 0 ? entries[at - 1] : nil
            focus = neighbour.map { .row($0.id) } ?? .filter(filter)
        }
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func load() async {
        guard let client = await requests.ready() else {
            problem = requests.client == nil ? nil : String(localized: "Seerr couldn't be reached.")
            loaded = true
            return
        }
        fetching = true
        defer { fetching = false }
        // As many as were listed, so a row that was acted on is still in view.
        let wanted = max(20, taken)
        guard let page = try? await client.requests(filter, sort: sort, take: wanted) else {
            problem = String(localized: "Seerr couldn't be reached.")
            loaded = true
            return
        }
        let listed = await client.titled(page.list).map { RequestEntry(request: $0.request, title: $0.title) }
        guard !Task.isCancelled else { return }
        entries = listed
        // One whose title can't be found isn't listed, and isn't waited for.
        taken = page.list.count
        dropped = page.list.count - listed.count
        total = page.total - dropped
        problem = nil
        loaded = true
    }

    private func more() async {
        guard loaded, !fetching, entries.count < total, let client = await requests.ready() else { return }
        fetching = true
        defer { fetching = false }
        let listing = Listing(filter: filter, sort: sort, revision: requests.revision)
        guard let page = try? await client.requests(filter, sort: sort, skip: taken, take: 20) else { return }
        let next = await client.titled(page.list).map { RequestEntry(request: $0.request, title: $0.title) }
        // Still the same list as when it was asked for.
        guard listing == Listing(filter: filter, sort: sort, revision: requests.revision) else { return }
        let have = Set(entries.map(\.id))
        entries += next.filter { !have.contains($0.id) }
        taken += page.list.count
        dropped += page.list.count - next.count
        total = page.total - dropped
        // Nothing came: no more is said to be coming, or the spinner would stay.
        if page.list.isEmpty { total = entries.count }
    }
}
