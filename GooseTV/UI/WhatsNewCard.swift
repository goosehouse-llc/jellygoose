import SwiftUI

/// "What's new": the version's highlights, over Home, once.
struct WhatsNewCard: View {
    let onClose: () -> Void
    @FocusState private var continueFocused: Bool

    var body: some View {
        PanelBackdrop(onTapOutside: close) {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WHAT'S NEW", comment: "Heading of the screen shown after an update, in capitals")
                        .font(.app(14, .heavy))
                        .kerning(1.8)
                        .foregroundStyle(Theme.accent)
                    Text("JellyGoose \(WhatsNew.version)")
                        .font(.app(34, .bold))
                }
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(WhatsNew.items) { item in
                        HStack(alignment: .top, spacing: 18) {
                            Image(systemName: item.icon)
                                .font(.app(22, .semibold))
                                .foregroundStyle(.white)
                                .frame(width: CGFloat(48).scaled, height: CGFloat(48).scaled)
                                .background(Theme.gradient(Theme.primary, start: .topLeading, end: .bottomTrailing),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.app(20, .semibold))
                                Text(item.detail)
                                    .font(.app(16))
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Button(String(localized: "Continue")) { close() }
                    .buttonStyle(GradientButtonStyle())
                    .focused($continueFocused)
                    .padding(.top, 6)
            }
            .frame(maxWidth: CGFloat(640).scaled, alignment: .leading)
        }
        .onAppear {
            // Shown counts as seen, however it's left.
            WhatsNew.markSeen()
            continueFocused = true
        }
    }

    private func close() { onClose() }
}
