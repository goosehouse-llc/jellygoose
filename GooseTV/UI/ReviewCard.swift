import SwiftUI
import CoreImage.CIFilterBuiltins

/// The Apple TV's request for a rating (see ReviewPrompt): what it's for, a code
/// that opens the review page on a phone, and two ways out, Back being the same as "Maybe Later".
struct ReviewCard: View {
    let onClose: () -> Void

    @FocusState private var laterFocused: Bool

    var body: some View {
        PanelBackdrop {
            HStack(alignment: .center, spacing: CGFloat(40).scaled) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Enjoying JellyGoose?")
                        .font(.app(34, .bold))
                    Text("A rating on the App Store helps other Jellyfin users find it. Scan the code with your phone to leave one — it takes a few seconds.")
                        .font(.app(20))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        Button(String(localized: "Maybe Later")) { onClose() }
                        .focused($laterFocused)
                        Button(String(localized: "Don't Ask Again")) {
                            ReviewPrompt.neverAgain()
                            onClose()
                        }
                    }
                    .buttonStyle(.pill(selected: false))
                    .padding(.top, 8)
                }
                .frame(width: CGFloat(520).scaled, alignment: .leading)

                if let code = QRCode.image(for: ReviewPrompt.reviewURL) {
                    Image(uiImage: code)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: CGFloat(220).scaled, height: CGFloat(220).scaled)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel(String(localized: "Code that opens JellyGoose's App Store review page"))
                }
            }
        }
        .onAppear {
            // Shown counts as asked, however it's left (Back included).
            ReviewPrompt.asked()
            laterFocused = true
        }
    }
}

/// A QR code, drawn crisp at any size (use with `.interpolation(.none)`).
enum QRCode {
    static func image(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
