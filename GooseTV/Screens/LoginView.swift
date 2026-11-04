import SwiftUI

struct LoginView: View {
    @EnvironmentObject var app: AppState
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorMessage: String?
    /// Accounts already signed in on this Apple TV, then anyone else the
    /// server lists on its own sign-in screen.
    @State private var accounts: [SavedAccount] = []
    @State private var publicUsers: [PublicUser] = []
    @FocusState private var passwordFocused: Bool
    /// Where focus starts: the first face, or the username with none to show,
    /// rather than Change Server, which is top left and would otherwise win.
    @FocusState private var startFocused: Int?

    // Quick Connect
    @State private var quickConnectAvailable = false
    @State private var quickConnectCode: String?
    @State private var quickConnectTask: Task<Void, Never>?
    @Environment(\.isNarrow) private var narrow

    var body: some View {
        // Side by side on a television or a tablet; one above the other, and
        // scrolling, on a phone.
        let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 32))
                            : AnyLayout(HStackLayout(alignment: .top, spacing: 70))
        return layout {
            VStack(alignment: .leading, spacing: narrow ? 28 : 40) {
                serverHeader
                if !accounts.isEmpty || !publicUsers.isEmpty {
                    whoIsWatching
                } else {
                    Text("Sign in")
                        .font(.app(narrow ? 48 : 64, .heavy))
                }
                credentials
            }
            .frame(maxWidth: CGFloat(880).scaled, alignment: .leading)

            if quickConnectAvailable {
                quickConnectCard
                    .frame(maxWidth: narrow ? .infinity : CGFloat(680).scaled)
                    .padding(.top, narrow ? 0 : 90)
            }
        }
        .padding(.horizontal, narrow ? 20 : 90)
        .padding(.vertical, narrow ? 24 : 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .scrollsVertically(narrow)
        .defaultFocus($startFocused, 0)
        .onAppear {
            // After an expired session, the same person is almost certainly signing back in.
            if app.signInNotice != nil, username.isEmpty, let name = app.userName { username = name }
        }
        .task {
            quickConnectAvailable = await app.client?.quickConnectEnabled() ?? false
        }
        .task { await loadUsers() }
        .onDisappear { quickConnectTask?.cancel() }
    }

    // MARK: The server

    /// Which server this is, always in view: signing in to the wrong one of two
    /// with the same name is easy otherwise.
    private var serverHeader: some View {
        HStack(spacing: 20) {
            Button {
                app.chooseAnotherServer()
            } label: {
                Label("Change Server", systemImage: "chevron.left")
            }
            .buttonStyle(.ghost)
            ServerBadge(flavor: app.serverFlavor, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(app.serverName ?? app.client?.baseURL.host() ?? "")
                        .font(.app(26, .heavy))
                        .lineLimit(1)
                    FlavorTag(flavor: app.serverFlavor)
                }
                if let url = app.client?.baseURL {
                    Text(verbatim: url.host().map { host in url.port.map { "\(host):\($0)" } ?? host } ?? url.absoluteString)
                        .font(.app(19))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .tvFocusSection()
    }

    // MARK: Who's watching

    private var whoIsWatching: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who's watching?", comment: "Heading above the profile pictures on the sign-in screen")
                .font(.app(56, .heavy))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 34) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        userTile(name: account.name, imageTag: account.imageTag, userId: account.userId) {
                            Task { await pick(account) }
                        }
                        .focused($startFocused, equals: index == 0 ? 0 : -1)
                        .contextMenu {
                            Button("Forget on This Apple TV", role: .destructive) {
                                SavedAccounts.forget(account)
                                Task { await loadUsers() }
                            }
                        }
                    }
                    ForEach(Array(publicUsers.enumerated()), id: \.element.id) { index, user in
                        userTile(name: user.name, imageTag: user.primaryImageTag, userId: user.id) {
                            Task { await pick(user) }
                        }
                        .focused($startFocused, equals: accounts.isEmpty && index == 0 ? 0 : -1)
                    }
                }
                .padding(.vertical, 30)
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)
        }
        .tvFocusSection()
    }

    private func userTile(name: String, imageTag: String?, userId: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            UserTileLabel(name: name, imageURL: app.client?.userImageURL(userId: userId, tag: imageTag))
        }
        .buttonStyle(UserTileStyle())
        .disabled(busy)
    }

    /// Everyone signed in here before comes first, then the server's own list
    /// without them.
    private func loadUsers() async {
        guard let client = app.client else { return }
        accounts = SavedAccounts.on(server: client.baseURL)
        let known = Set(accounts.map(\.userId))
        publicUsers = await client.publicUsers().filter { !known.contains($0.id) }
    }

    /// An account signed in here before: in without a password, unless the
    /// server has since revoked it.
    private func pick(_ account: SavedAccount) async {
        errorMessage = nil
        busy = true
        defer { busy = false }
        if await app.signIn(as: account) {
            quickConnectTask?.cancel()
            return
        }
        username = account.name
        password = ""
        errorMessage = String(localized: "Enter the password for \(account.name).", comment: "The placeholder is a user name")
        passwordFocused = true
        await loadUsers()
    }

    /// Someone the server lists. Tried without a password first, since
    /// accounts without one are common at home and the server's own flag for
    /// it can't be trusted; if that's refused, the password is asked for.
    private func pick(_ user: PublicUser) async {
        errorMessage = nil
        username = user.name
        password = ""
        guard let client = app.client else { return }
        busy = true
        defer { busy = false }
        if let auth = try? await client.authenticate(username: user.name, password: "") {
            quickConnectTask?.cancel()
            app.signedIn(auth)
            return
        }
        passwordFocused = true
    }

    // MARK: Credentials

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let notice = app.signInNotice {
                Label(notice, systemImage: "clock.badge.exclamationmark")
                    .font(.app(22, .semibold))
                    .foregroundStyle(Theme.palette[1].1)
            }

            fieldLabel(String(localized: "Username"))
            TextField("Username", text: $username)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.next)
                .onSubmit { passwordFocused = true }
                .touchField()
                .frame(maxWidth: narrow ? .infinity : CGFloat(640).scaled)
                .focused($startFocused, equals: accounts.isEmpty && publicUsers.isEmpty ? 0 : -1)
            fieldLabel(String(localized: "Password"))
            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($passwordFocused)
                .submitLabel(.go)
                .onSubmit { if !username.isEmpty, !busy { Task { await signIn() } } }
                .touchField()
                .frame(maxWidth: narrow ? .infinity : CGFloat(640).scaled)

            if app.client?.baseURL.scheme == "http" {
                Label("This connection isn't encrypted. Your password is sent as typed.",
                      systemImage: "lock.open")
                    .font(.app(19, .semibold))
                    .foregroundStyle(Theme.palette[1].1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await signIn() }
            } label: {
                Group {
                    if busy { ProgressView() } else { Text("Sign In") }
                }
                .frame(maxWidth: narrow ? .infinity : CGFloat(584).scaled)
            }
            .buttonStyle(GradientButtonStyle())
            .disabled(username.isEmpty || busy)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Theme.palette[1].1)
                    .font(.app(22, .semibold))
            }
        }
        .tvFocusSection()
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.app(15, .heavy))
            .kerning(1.6)
            .foregroundStyle(Theme.textSecondary)
            .padding(.bottom, -12)
    }

    // MARK: Quick Connect

    /// Signing in from a phone instead, with the code big enough to read
    /// from the sofa.
    private var quickConnectCard: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.accent.opacity(0.18))
                    .frame(width: CGFloat(60).scaled, height: CGFloat(60).scaled)
                    .overlay {
                        Image(systemName: "iphone")
                            .font(.app(28, .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                Text("Quick Connect", comment: "Name of a Jellyfin sign-in feature; usually left untranslated")
                    .font(.app(36, .heavy))
            }

            if let code = quickConnectCode {
                HStack(spacing: 10) {
                    ForEach(Array(code.enumerated()), id: \.offset) { index, digit in
                        Text(String(digit))
                            .font(.app(narrow ? 40 : 56, .heavy))
                            .monospacedDigit()
                            .frame(width: CGFloat(narrow ? 44 : 78).scaled, height: CGFloat(narrow ? 64 : 100).scaled)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                        if index == code.count / 2 - 1 { Spacer().frame(width: 12) }
                    }
                }
                .frame(maxWidth: .infinity)
                Text("Enter this code in the \(app.serverFlavor.label) app\nor web dashboard on another device.")
                    .font(.app(22))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(.white.opacity(0.1))
                HStack {
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.accent).frame(width: 10, height: 10)
                            Circle().fill(Theme.accent.opacity(0.55)).frame(width: 10, height: 10)
                            Circle().fill(Theme.accent.opacity(0.25)).frame(width: 10, height: 10)
                        }
                        Text("Waiting for approval", comment: "Quick Connect: the code is shown and the app is waiting for it to be entered")
                            .font(.app(20, .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button {
                        startQuickConnect()
                    } label: {
                        Label("New code", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.ghost)
                }
            } else {
                Text("Enter a code on your phone or computer instead of typing here.",
                     comment: "Quick Connect card before a code is asked for")
                    .font(.app(22))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Get a code") { startQuickConnect() }
                    .buttonStyle(GradientButtonStyle())
            }
        }
        .padding(50)
        .background {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(.black.opacity(0.45))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 36, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                }
        }
        .tvFocusSection()
    }

    private func signIn() async {
        guard let client = app.client else { return }
        errorMessage = nil
        busy = true
        defer { busy = false }
        do {
            let auth = try await client.authenticate(username: username, password: password)
            quickConnectTask?.cancel()
            app.signedIn(auth)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startQuickConnect() {
        guard let client = app.client else { return }
        quickConnectTask?.cancel()
        quickConnectTask = Task {
            do {
                let initiated = try await client.quickConnectInitiate()
                quickConnectCode = initiated.code
                // Poll until approved on another device.
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(3))
                    let state = try await client.quickConnectState(secret: initiated.secret)
                    if state.authenticated {
                        let auth = try await client.authenticateWithQuickConnect(secret: initiated.secret)
                        app.signedIn(auth)
                        return
                    }
                }
            } catch {
                if !Task.isCancelled {
                    quickConnectCode = nil
                    errorMessage = String(localized: "Quick Connect failed. Try again or sign in with a password.", comment: "Quick Connect is the name of a Jellyfin feature")
                }
            }
        }
    }
}

/// A face and a name, ringed in white while highlighted, the way the rest of
/// the app turns a focused control white.
private struct UserTileLabel: View {
    let name: String
    let imageURL: URL?
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.gradient(Theme.primary, start: .topLeading, end: .bottomTrailing))
                Text(String(name.prefix(1)).uppercased())
                    .font(.app(52, .heavy))
                    .foregroundStyle(.white)
                if let imageURL {
                    RemoteImage(url: imageURL).clipShape(Circle())
                }
            }
            .frame(width: 150, height: 150)
            .overlay(Circle().stroke(.white, lineWidth: focused ? 6 : 0).padding(-8))
            .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 18, y: 10)
            Text(name)
                .font(.app(24, focused ? .bold : .semibold))
                .foregroundStyle(focused ? .white : Theme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 190)
        }
        .scaleEffect(focused ? 1.1 : 1)
        .animation(.easeOut(duration: 0.14), value: focused)
    }
}

/// No system focus effect: the label draws its own.
private struct UserTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
