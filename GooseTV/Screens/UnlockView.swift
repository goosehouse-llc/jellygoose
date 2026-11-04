import StoreKit
import SwiftUI

/// The unlock screen: the trial, what ends with it, and what the unlock
/// costs, said before the trial can be started (as App Review asks), with
/// the trial, the unlock and Restore Purchases. Shown when something was to
/// play and may not, and from Settings.
struct UnlockView: View {
    @ObservedObject private var unlock = Unlock.shared
    @Environment(\.purchase) private var purchase
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.78).ignoresSafeArea()
            VStack(alignment: .leading, spacing: CGFloat(18).scaled) {
                Text(title)
                    .font(.app(30, .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.app(18))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                if unlock.state != .unlocked {
                    Group {
                        #if os(macOS)
                        Text(String(localized: "One purchase covers Mac, iPhone, iPad and Apple TV on the same Apple Account.",
                                    comment: "Unlock screen on a Mac: the unlock is shared by every device on the account"))
                        #else
                        Text(String(localized: "One purchase covers iPhone, iPad and Apple TV on the same Apple Account.",
                                    comment: "Unlock screen: the unlock is shared by every device on the account"))
                        #endif
                    }
                        .font(.app(15))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let failure = unlock.failure {
                    Text(failure).font(.app(15)).foregroundStyle(Theme.palette[1].0)
                }
                buttons
                    .padding(.top, CGFloat(6).scaled)
            }
            .padding(CGFloat(34).scaled)
            .frame(maxWidth: Self.width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 26).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.1), lineWidth: 1))
            .padding(24)
        }
        .foregroundStyle(.white)
        .task { await unlock.loadProducts() }
        #if os(tvOS)
        .onExitCommand { close() }
        #endif
    }

    #if os(tvOS)
    private static let width: CGFloat = 1000
    #else
    private static let width: CGFloat = 520
    #endif

    private var price: String? { unlock.unlock?.displayPrice }

    private var title: String {
        switch unlock.state {
        case .unlocked: String(localized: "JellyGoose is unlocked", comment: "Unlock screen title once bought, or for someone who had the app before it was sold")
        case .trial: String(localized: "Days left in your free trial: \(unlock.daysLeft ?? 1)", comment: "Unlock screen title during the trial. The placeholder is a number of days, 1 to 7")
        case .trialEnded: String(localized: "Your free trial has ended", comment: "Unlock screen title after the seven days")
        case .notStarted, .checking: String(localized: "Try JellyGoose free for \(Unlock.trialDays) days", comment: "Unlock screen title before the trial. The placeholder is the number of days, 7")
        }
    }

    private var message: String {
        if unlock.state == .unlocked {
            return String(localized: "Everything plays, on every device signed in to this Apple Account. Thank you.",
                          comment: "Unlock screen once unlocked")
        }
        guard let price else {
            return String(localized: "Everything works for \(Unlock.trialDays) days. After that, playing films, shows and Live TV needs a one-time unlock. Browsing your server stays free.",
                          comment: "Unlock screen, while the price is still being fetched. The placeholder is the number of days, 7")
        }
        return String(localized: "Everything works for \(Unlock.trialDays) days. After that, playing films, shows and Live TV needs a one-time unlock for \(price). Browsing your server stays free.",
                      comment: "Unlock screen. The placeholders are the number of days (7) and the unlock's price")
    }

    @ViewBuilder
    private var buttons: some View {
        let stack = Self.horizontal ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        stack {
            switch unlock.state {
            case .unlocked:
                Button(String(localized: "Close")) { close() }
                    .buttonStyle(GradientButtonStyle())
            case .notStarted, .checking:
                // The trial can't start before the price it leads to is known
                // and on the screen.
                Button(String(localized: "Start Free Trial", comment: "Unlock screen: starts the seven-day trial")) {
                    Task { await buy(unlock.trial) }
                }
                .buttonStyle(GradientButtonStyle())
                .disabled(unlock.trial == nil || price == nil || unlock.busy)
                unlockButton(primary: false)
                restoreButton
                Button(String(localized: "Not Now", comment: "Unlock screen: puts it away")) { close() }
                    .buttonStyle(.ghost)
            case .trial:
                unlockButton(primary: true)
                restoreButton
                Button(String(localized: "Close")) { close() }
                    .buttonStyle(.ghost)
            case .trialEnded:
                unlockButton(primary: true)
                restoreButton
                Button(String(localized: "Not Now", comment: "Unlock screen: puts it away")) { close() }
                    .buttonStyle(.ghost)
            }
            if unlock.busy { ProgressView() }
        }
    }

    #if os(tvOS)
    private static let horizontal = true
    #else
    private static let horizontal = false
    #endif

    @ViewBuilder
    private func unlockButton(primary: Bool) -> some View {
        let label = price.map { String(localized: "Unlock for \($0)", comment: "Unlock screen: buys the unlock. The placeholder is its price") }
            ?? String(localized: "Unlock", comment: "Unlock screen: buys the unlock, before its price is known")
        if primary {
            Button(label) { Task { await buy(unlock.unlock) } }
                .buttonStyle(GradientButtonStyle())
                .disabled(unlock.unlock == nil || unlock.busy)
        } else {
            Button(label) { Task { await buy(unlock.unlock) } }
                .buttonStyle(.ghost)
                .disabled(unlock.unlock == nil || unlock.busy)
        }
    }

    private var restoreButton: some View {
        Button(String(localized: "Restore Purchases", comment: "Unlock screen: brings back an unlock or a trial already had on this Apple Account")) {
            Task {
                await unlock.restore()
                if unlock.mayPlay { close() }
            }
        }
        .buttonStyle(.ghost)
        .disabled(unlock.busy)
    }

    private func buy(_ product: Product?) async {
        guard let product else { return }
        unlock.failure = nil
        unlock.busy = true
        defer { unlock.busy = false }
        do {
            let result = try await purchase(product)
            await unlock.take(result)
            if case .success = result, unlock.mayPlay { close() }
        } catch {
            unlock.failure = error.localizedDescription
        }
    }
}

// The Mac's is in macOS/MacUnlockStage.swift: a panel of its own.
#if !os(macOS)
/// Where the unlock screen is shown: a window of its own over the whole app,
/// the player's included, on the phone's or the television's screen (never
/// the car's: a purchase is confirmed on the phone).
@MainActor
final class UnlockStage {
    static let shared = UnlockStage()
    private var window: UIWindow?

    func show() {
        guard window == nil, let scene = Self.scene else { return }
        let stage = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: UnlockView { [weak self] in self?.hide() }
            .preferredColorScheme(.dark))
        host.view.backgroundColor = .clear
        stage.rootViewController = host
        // Over the player's own window (see `PlayerStage`).
        stage.windowLevel = .normal + 2
        stage.overrideUserInterfaceStyle = .dark
        stage.makeKeyAndVisible()
        window = stage
    }

    func hide() {
        guard let stage = window else { return }
        window = nil
        stage.isHidden = true
        stage.rootViewController = nil
        stage.windowScene?.windows.first { !$0.isHidden && $0 !== stage }?.makeKey()
        Unlock.shared.finished()
    }

    private static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        #if os(iOS)
        let screens = scenes.filter { !$0.isCarScreen }
        #else
        let screens = scenes
        #endif
        return screens.first { $0.activationState == .foregroundActive } ?? screens.first
    }
}
#endif
