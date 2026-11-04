import SwiftUI

/// An iPhone Duo standing half-open like a small laptop, its fold running
/// across the player: the picture goes above the fold and the controls below
/// it, where they stay up, as Apple's own player does. Nowhere else is there
/// such a fold, and the player is laid out as it always was.
struct TabletopFold: Equatable {
    /// Where the fold's band starts and ends, down the player.
    let top: CGFloat
    let bottom: CGFloat
}

private struct PlayerTabletopKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The controls have the half of the screen below the fold to themselves.
    var playerTabletop: Bool {
        get { self[PlayerTabletopKey.self] }
        set { self[PlayerTabletopKey.self] = newValue }
    }
}

extension View {
    /// Keeps `fold` up to date with a fold across this view (see TabletopFold).
    func readsTabletopFold(_ fold: Binding<TabletopFold?>) -> some View {
        #if os(iOS)
        background { TabletopFoldReader(fold: fold) }
        #else
        self
        #endif
    }

    /// The picture: above the fold when there's one across the player. Only
    /// the frame changes, so the picture isn't rebuilt as the phone folds.
    func aboveTabletopFold(_ fold: TabletopFold?) -> some View {
        frame(height: fold?.top)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The controls: below the fold when there's one across the player.
    func belowTabletopFold(_ fold: TabletopFold?) -> some View {
        padding(.top, fold?.bottom ?? 0)
            .environment(\.playerTabletop, fold != nil)
    }
}

#if os(iOS)
private struct TabletopFoldReader: View {
    @Binding var fold: TabletopFold?
    /// Bumped as the hinge moves, to read the fold again: the regions can
    /// change while the player's size doesn't.
    @State private var hingeMoves = 0

    var body: some View {
        #if DEBUG
        // GOOSETV_FAKE_FOLD=0.5: a fold across the player that far down, as a
        // Duo would have it standing half-open (Device Hub can't be driven by
        // script), on any simulator.
        if let at = ProcessInfo.processInfo.environment["GOOSETV_FAKE_FOLD"].flatMap(Double.init) {
            GeometryReader { proxy in
                let y = proxy.size.height * at
                let found = TabletopFold(top: y - 20, bottom: y + 20)
                Color.clear
                    .onAppear { fold = found }
                    .onChange(of: found) { _, new in fold = new }
            }
            .ignoresSafeArea()
        } else {
            folds
        }
        #else
        folds
        #endif
    }

    @ViewBuilder
    private var folds: some View {
        if #available(iOS 27.1, *) {
            GeometryReader { proxy in
                let _ = hingeMoves
                let found = Self.fold(in: proxy)
                Color.clear
                    .onAppear { if fold != found { fold = found } }
                    .onChange(of: found) { _, new in fold = new }
            }
            .ignoresSafeArea()
            .onHingeChange { _, _ in hingeMoves += 1 }
        }
    }

    /// A band the system keeps for the fold, lying across the player near
    /// its middle: the Duo's open screen held upright, its lower half flat
    /// on a table. A fold down the middle (the screen on its side, half-open
    /// like a book) isn't one: the player stays as it is then.
    @available(iOS 27.1, *)
    private static func fold(in proxy: GeometryProxy) -> TabletopFold? {
        let size = proxy.size
        for region in proxy.reservedRegions(kind: .division) where region.isActive {
            let band = region.frame
            if band.width >= size.width * 0.8, band.height < size.height * 0.25,
               band.midY > size.height * 0.3, band.midY < size.height * 0.7 {
                return TabletopFold(top: band.minY, bottom: band.maxY)
            }
        }
        return nil
    }
}
#endif
