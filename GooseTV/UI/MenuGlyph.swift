import SwiftUI

/// The menu's own icons: outlines drawn on a 24-point grid and stroked, so the
/// sections read as one set, the way they're drawn on jellygoose.app, rather
/// than Apple's filled symbols in their several weights.
enum MenuGlyph: String {
    case home = "glyph.home"
    case libraries = "glyph.libraries"
    case favourites = "glyph.favourites"
    case collections = "glyph.collections"
    case search = "glyph.search"

    /// The outline, in the 24 × 24 box it's drawn in.
    fileprivate var path: Path {
        var p = Path()
        switch self {
        case .home:
            // A house with a door: the roof, then down and round to the door.
            p.move(to: CGPoint(x: 4, y: 11))
            p.addLine(to: CGPoint(x: 12, y: 4))
            p.addLine(to: CGPoint(x: 20, y: 11))
            p.addLine(to: CGPoint(x: 20, y: 20))
            p.addQuadCurve(to: CGPoint(x: 19, y: 21), control: CGPoint(x: 20, y: 21))
            p.addLine(to: CGPoint(x: 14, y: 21))
            p.addLine(to: CGPoint(x: 14, y: 15))
            p.addLine(to: CGPoint(x: 10, y: 15))
            p.addLine(to: CGPoint(x: 10, y: 21))
            p.addLine(to: CGPoint(x: 5, y: 21))
            p.addQuadCurve(to: CGPoint(x: 4, y: 20), control: CGPoint(x: 4, y: 21))
            p.closeSubpath()
        case .libraries:
            // A framed panel with a header and a side column.
            p.addRoundedRect(in: CGRect(x: 3, y: 4, width: 18, height: 16), cornerSize: CGSize(width: 2.5, height: 2.5))
            p.move(to: CGPoint(x: 3, y: 9))
            p.addLine(to: CGPoint(x: 21, y: 9))
            p.move(to: CGPoint(x: 8.5, y: 9))
            p.addLine(to: CGPoint(x: 8.5, y: 20))
        case .favourites:
            p.move(to: CGPoint(x: 12, y: 20.5))
            p.addCurve(to: CGPoint(x: 4, y: 9.5), control1: CGPoint(x: 7, y: 17), control2: CGPoint(x: 4, y: 13.5))
            p.addCurve(to: CGPoint(x: 8.3, y: 5), control1: CGPoint(x: 4, y: 6.8), control2: CGPoint(x: 6, y: 5))
            p.addCurve(to: CGPoint(x: 12, y: 7.3), control1: CGPoint(x: 10, y: 5), control2: CGPoint(x: 11.3, y: 6))
            p.addCurve(to: CGPoint(x: 15.7, y: 5), control1: CGPoint(x: 12.7, y: 6), control2: CGPoint(x: 14, y: 5))
            p.addCurve(to: CGPoint(x: 20, y: 9.5), control1: CGPoint(x: 18, y: 5), control2: CGPoint(x: 20, y: 6.8))
            p.addCurve(to: CGPoint(x: 12, y: 20.5), control1: CGPoint(x: 20, y: 13.5), control2: CGPoint(x: 17, y: 17))
            p.closeSubpath()
        case .collections:
            // A box with two shorter lids stacked on it.
            p.addRoundedRect(in: CGRect(x: 4, y: 9, width: 16, height: 12), cornerSize: CGSize(width: 2.5, height: 2.5))
            p.move(to: CGPoint(x: 7, y: 6))
            p.addLine(to: CGPoint(x: 17, y: 6))
            p.move(to: CGPoint(x: 9, y: 3))
            p.addLine(to: CGPoint(x: 15, y: 3))
        case .search:
            p.addEllipse(in: CGRect(x: 4, y: 4, width: 14, height: 14))
            p.move(to: CGPoint(x: 16, y: 16))
            p.addLine(to: CGPoint(x: 20.5, y: 20.5))
        }
        return p
    }
}

/// A menu glyph at a size, stroked in the current foreground style.
struct MenuGlyphView: View {
    let glyph: MenuGlyph
    let size: CGFloat

    var body: some View {
        GlyphShape(glyph: glyph)
            .stroke(style: StrokeStyle(lineWidth: size / 12, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

private struct GlyphShape: Shape {
    let glyph: MenuGlyph

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        return glyph.path.applying(CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: rect.minX / scale, y: rect.minY / scale))
    }
}
