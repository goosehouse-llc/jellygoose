import Foundation
import StoreKit
#if os(macOS)
import Security
#endif

/// Whether this Apple ID may play. From 1.7.1 JellyGoose is free to try for
/// seven days, then a one-time unlock; browsing a server is free throughout.
///
/// The App Store has no trial for a one-off purchase, so it's done the way
/// App Review allows (guideline 3.1.1): two non-consumable purchases, a
/// free one named "7-day Trial" whose date starts the clock, and the unlock
/// itself. Both belong to the one App Store record, so a trial or an unlock
/// on the iPhone holds on the iPad and the Apple TV too, and deleting the app
/// doesn't start the trial over.
///
/// Whoever had the app before the trial began keeps it as it was: the App
/// Store says which build they first downloaded (`AppTransaction`).
@MainActor
final class Unlock: ObservableObject {
    static let shared = Unlock()

    static let trialID = "com.goosehouse.jellygoose.trial7"
    static let unlockID = "com.goosehouse.jellygoose.unlock"
    static let trialDays = 7
    /// The first build sold with the trial. A first download older than this
    /// was the app when it was free, and stays unlocked.
    static let firstTrialBuild = 101

    enum State: Equatable {
        /// Not known yet: just launched.
        case checking
        /// Bought, or had before the trial began.
        case unlocked
        case trial(ends: Date)
        case trialEnded
        /// Never tried.
        case notStarted
    }

    @Published private(set) var state: State = .checking
    @Published private(set) var trial: Product?
    @Published private(set) var unlock: Product?
    /// A purchase or a restore under way.
    @Published var busy = false
    @Published var failure: String?

    private var updates: Task<Void, Never>?
    /// What to do once playing is allowed: the film or channel that was
    /// turned away, played after all.
    private var then: (() -> Void)?
    /// When the unlock screen was last put away unanswered: a channel tuned
    /// again soon after doesn't bring it straight back.
    private var declinedAt = Date.distantPast

    /// Whether something may start playing now. While the store is still
    /// being asked, yes: someone who owns it isn't to be stopped at launch.
    var mayPlay: Bool {
        switch state {
        case .checking, .unlocked: return true
        case .trial(let ends): return ends > Date()
        case .trialEnded, .notStarted: return false
        }
    }

    /// Days of the trial left, counting today.
    var daysLeft: Int? {
        guard case .trial(let ends) = state else { return nil }
        return max(1, Int(ceil(ends.timeIntervalSinceNow / 86_400)))
    }

    // MARK: Finding out

    /// Reads what this Apple ID owns, at launch and whenever the app comes
    /// back: a trial runs out while the app's away, a purchase arrives from
    /// another device.
    func refresh() async {
        listen()
        if let forced = Self.forcedForTesting { state = forced; await loadProducts(); return }
        // The developer's own installs (from Xcode, not the App Store) aren't
        // sold, and have nothing to unlock with.
        if Self.isDeveloperInstall { state = .unlocked; return }
        var trialStarted: Date?
        var bought = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            if transaction.productID == Self.unlockID { bought = true }
            if transaction.productID == Self.trialID { trialStarted = transaction.purchaseDate }
        }
        let hadItBefore = bought ? true : await hadAppBeforeTrial()
        if hadItBefore {
            state = .unlocked
            return
        }
        if let trialStarted {
            let ends = trialStarted.addingTimeInterval(TimeInterval(Self.trialDays * 86_400))
            state = ends > Date() ? .trial(ends: ends) : .trialEnded
        } else {
            state = .notStarted
        }
        await loadProducts()
    }

    /// Whether the first download of the app on this Apple ID came before
    /// the trial. If the App Store can't be asked (no connection), yes, for
    /// now: nobody who paid nothing for the app before is to be stopped for
    /// want of a network; it's asked again next time.
    private func hadAppBeforeTrial() async -> Bool {
        guard let result = try? await AppTransaction.shared else { return true }
        guard case .verified(let app) = result else { return false }
        // The build number of the first download, on iOS and tvOS. In the
        // sandbox it's "1.0", which isn't one: App Review sees the trial. On a
        // Mac it's the version ("1.9"), which isn't one either: the Mac app came
        // after the trial began, so nobody had it free there.
        guard let first = Int(app.originalAppVersion) else { return false }
        return first < Self.firstTrialBuild
    }

    func loadProducts() async {
        guard trial == nil || unlock == nil else { return }
        let found = (try? await Product.products(for: [Self.trialID, Self.unlockID])) ?? []
        trial = found.first { $0.id == Self.trialID }
        unlock = found.first { $0.id == Self.unlockID }
    }

    /// Takes in purchases completed out of sight: one approved later, or
    /// made on another device.
    private func listen() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
    }

    // MARK: Asking

    /// Something was about to play and may not: the unlock screen comes up,
    /// and `then` runs if playing is allowed by the time it's put away.
    /// `insist` false for a channel tuned again just after the screen was
    /// put away unanswered, so it isn't brought straight back.
    func ask(insist: Bool = true, then: (() -> Void)? = nil) {
        guard insist || Date().timeIntervalSince(declinedAt) > 60 else { return }
        self.then = then
        Task { await loadProducts() }
        UnlockStage.shared.show()
    }

    /// The unlock screen was put away.
    func finished() {
        if mayPlay, let then {
            self.then = nil
            then()
        } else {
            then = nil
            declinedAt = Date()
        }
    }

    /// The result of a purchase made from the unlock screen.
    func take(_ result: Product.PurchaseResult) async {
        if case .success(.verified(let transaction)) = result {
            await transaction.finish()
        }
        await refresh()
    }

    func restore() async {
        busy = true
        defer { busy = false }
        do {
            try await AppStore.sync()
        } catch {
            failure = error.localizedDescription
        }
        await refresh()
    }

    // MARK: Testing

    /// Installed from Xcode or by the developer, not from the App Store or
    /// TestFlight: such a build carries the profile it was signed with. A
    /// simulator too, which has no App Store to ask: there the question puts
    /// up a sign-in to an Apple Account over the app.
    private static var isDeveloperInstall: Bool {
        #if targetEnvironment(simulator)
        return true
        #elseif os(macOS)
        // A Mac app carries a provisioning profile from the App Store too, so the
        // profile says nothing: a development build is the one a debugger may attach to.
        return signedForDevelopment
        #else
        return Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
        #endif
    }

    #if os(macOS)
    /// Whether this copy's signature lets a debugger attach (`get-task-allow`), as a
    /// development build's does and an App Store or TestFlight build's doesn't.
    private static let signedForDevelopment: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let signing = info as? [String: Any],
              let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements["com.apple.security.get-task-allow"] as? Bool == true
    }()
    #endif

    /// `GOOSETV_UNLOCK` sets the state for a test or a screenshot: fresh,
    /// trial, ended or unlocked.
    private static var forcedForTesting: State? {
        switch ProcessInfo.processInfo.environment["GOOSETV_UNLOCK"] {
        case "fresh": .notStarted
        case "trial": .trial(ends: Date().addingTimeInterval(5 * 86_400))
        case "ended": .trialEnded
        case "unlocked": .unlocked
        default: nil
        }
    }
}
