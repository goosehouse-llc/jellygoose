#if os(macOS)
import SwiftUI

/// Search's field on the Mac: across the top of the page, as the iPhone's sits across the top
/// of its screen. (SwiftUI's searchable puts it in the window's title bar, which the app's
/// window doesn't show, so it was squeezed in beside the window's buttons.) It has the keys as
/// the page opens, so typing goes straight in; Escape clears it.
struct MacSearchField: View {
    @Binding var text: String
    let prompt: Text
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.app(19, .semibold))
                .foregroundStyle(Theme.textSecondary)
            TextField(text: $text, prompt: prompt) { EmptyView() }
                .textFieldStyle(.plain)
                .font(.app(21))
                .focused($focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.app(17))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.white.opacity(focused ? 0.35 : 0.12), lineWidth: 1))
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.horizontal, Theme.pageMargin)
        .padding(.top, 36)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { focused = true }
    }
}
#endif
