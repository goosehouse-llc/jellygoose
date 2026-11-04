import SwiftUI

// What can be done with a request, and how one is described: shared by a
// title's page and the list of requests.

extension SeerrRequest {
    /// What someone may do with a request, as Seerr's own list offers it.
    enum Action: Hashable {
        case approve, decline
        /// Handing on again one that was approved but didn't get through.
        case retry
        /// Taking back one's own while it still waits.
        case cancel
        case delete

        var label: String {
            switch self {
            case .approve: String(localized: "Approve", comment: "Says yes to someone's request")
            case .decline: String(localized: "Decline", comment: "Says no to someone's request")
            case .retry: String(localized: "Retry", comment: "Sends a failed request on to be fetched again")
            case .cancel: String(localized: "Cancel Request", comment: "Takes back the viewer's own request")
            case .delete: String(localized: "Delete Request", comment: "Removes a request, whoever made it")
            }
        }

        /// Asked twice before it's done: there's no taking these back.
        var confirms: Bool { self == .decline || self == .cancel || self == .delete }
    }

    /// Someone who manages requests answers the waiting ones, sends failed
    /// ones on again and deletes any. Anyone else may take back their own
    /// while it waits, and nothing more.
    func actions(for user: SeerrUser?) -> [Action] {
        guard let user else { return [] }
        if user.managesRequests {
            return (waiting ? [.approve, .decline] : []) + (failed ? [.retry] : []) + [.delete]
        }
        return waiting && requestedBy?.id == user.id ? [.cancel] : []
    }

    /// The seasons it's for, where it's for some of a show: "Seasons 1, 2".
    var seasonsText: String? {
        let numbers = (seasons ?? []).map(\.seasonNumber).sorted()
        guard let first = numbers.first else { return nil }
        if numbers.count == 1 { return String(localized: "Season \(first)") }
        return String(localized: "Seasons \(numbers.map(String.init).joined(separator: ", "))",
                      comment: "The seasons a request is for; the placeholder is their numbers, like 1, 2, 3")
    }

    /// Who asked and how long ago: "Requested by Sam · 3 days ago". The name
    /// is left out where every request shown is the viewer's own.
    func byline(naming: Bool) -> String {
        var parts: [String] = []
        if naming, let name = requestedBy?.displayName {
            parts.append(String(localized: "Requested by \(name)", comment: "The placeholder is the name of whoever made a request"))
        }
        if let asked {
            parts.append(asked.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }
}

/// The buttons for what the viewer may do with one request. Those that can't
/// be taken back ask to be pressed a second time, as Seerr's do.
struct RequestActionButtons: View {
    let request: SeerrRequest
    @ObservedObject var requests: Requests
    /// The request has changed or gone, and the lists are about to be told:
    /// the time to move focus off buttons that won't be there.
    var settled: (SeerrRequest.Action) async -> Void = { _ in }
    var failed: (String) -> Void = { _ in }

    @State private var busy = false
    @State private var confirming: SeerrRequest.Action?
    @FocusState private var focused: SeerrRequest.Action?

    var body: some View {
        let actions = request.actions(for: requests.user)
        if !actions.isEmpty {
            HStack(spacing: 12) {
                ForEach(actions, id: \.self) { action in
                    Button(confirming == action ? String(localized: "Are You Sure?", comment: "A button's second press confirms it")
                                                : action.label) { press(action) }
                        .buttonStyle(.pill(selected: action == .approve))
                        .focused($focused, equals: action)
                }
                if busy { ProgressView() }
            }
            // Moving off a button that was asking takes the question back.
            .onChange(of: focused) { _, now in
                if now != confirming { confirming = nil }
            }
        }
    }

    private func press(_ action: SeerrRequest.Action) {
        // Not disabled while busy: a focused button that goes dead sends
        // focus off to the menu.
        guard !busy else { return }
        if action.confirms, confirming != action {
            confirming = action
            return
        }
        confirming = nil
        busy = true
        Task {
            defer { busy = false }
            guard let client = await requests.ready() else {
                failed(String(localized: "Seerr couldn't be reached."))
                return
            }
            do {
                switch action {
                case .approve: try await client.approve(request)
                case .decline: try await client.decline(request)
                case .retry: try await client.retry(request)
                case .cancel, .delete: try await client.remove(request)
                }
                await settled(action)
                requests.asked()
            } catch {
                failed(error.localizedDescription)
            }
        }
    }
}
