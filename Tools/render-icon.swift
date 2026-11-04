// Usage (from the project root):
//   swift Tools/render-icon.swift GooseTV/Assets.xcassets GooseTV/Resources/Fonts
// Renders every JellyGoose app icon: the default "Movie Night" set (brand assets
// plus Top Shelf banners) and the alternates the user can pick in Settings, each
// a layered image stack. All geometry is in the mockup's 400x240 unit space.
import AppKit
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args[1])
let fontDir = URL(fileURLWithPath: args[2])
for name in ["Figtree-SemiBold", "Figtree-Black", "Figtree-Medium"] {
    CTFontManagerRegisterFontsForURL(fontDir.appendingPathComponent("\(name).ttf") as CFURL, .process, nil)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}
let violet = gradient([(0, rgb(0x7A45E6)), (1, rgb(0x0090DB))])

/// A canvas whose drawing coordinates are the mockup's units (y down), scaled to pixels.
func canvas(px w: Int, _ h: Int, unitsHigh: CGFloat = 240) -> (CGContext, CGFloat, CGFloat) {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(h) / unitsHigh
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: s, y: -s)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return (ctx, s, CGFloat(w) / s)   // context, px-per-unit, width in units
}

func save(_ ctx: CGContext, _ rel: String) {
    let url = outDir.appendingPathComponent(rel)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(rel) \(ctx.width)x\(ctx.height)")
}

func roundRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

// MARK: - Scene pieces

/// Night room: base color plus two elliptical glows (SVG objectBoundingBox radial gradients).
func drawRoom(_ ctx: CGContext, width W: CGFloat, height H: CGFloat = 240) {
    ctx.setFillColor(rgb(0x0D0D14)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    func ellipseGlow(cx: CGFloat, cy: CGFloat, r: CGFloat, _ g: CGGradient) {
        ctx.saveGState()
        ctx.translateBy(x: cx * W, y: cy * H)
        ctx.scaleBy(x: 1, y: H / W)
        ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r * W, options: [])
        ctx.restoreGState()
    }
    ellipseGlow(cx: 0.7, cy: 0.25, r: 0.8, gradient([(0, rgb(0x3B2E6E)), (0.55, rgb(0x1A1438, 0.6)), (1, rgb(0x0D0D14, 0))]))
    ellipseGlow(cx: 0.25, cy: 0.85, r: 0.7, gradient([(0, rgb(0x123A5C)), (1, rgb(0x0D0D14, 0))]))
}

/// Soft halo behind the TV: the glow rect blurred (SVG stdDeviation 18) at 90% opacity.
func drawScreenHalo(_ ctx: CGContext, pxPerUnit s: CGFloat, transform: CGAffineTransform) {
    let (glow, _, _) = canvas(px: ctx.width, ctx.height, unitsHigh: CGFloat(ctx.height) / s)
    glow.concatenate(transform)
    glow.addPath(roundRect(180, 26, 200, 116, 16)); glow.clip()
    glow.drawLinearGradient(violet, start: CGPoint(x: 180, y: 26), end: CGPoint(x: 380, y: 142), options: [])
    let ci = CIImage(cgImage: glow.makeImage()!)
    let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: 18 * s).cropped(to: ci.extent)
    let out = CIContext().createCGImage(blurred, from: ci.extent)!
    ctx.saveGState()
    ctx.resetToPixels()
    ctx.setAlpha(0.9)
    ctx.draw(out, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    ctx.restoreGState()
}

func drawScreenAndBeam(_ ctx: CGContext) {
    let screen = roundRect(190, 34, 180, 100, 12)
    ctx.saveGState(); ctx.addPath(screen); ctx.clip()
    ctx.drawLinearGradient(violet, start: CGPoint(x: 190, y: 34), end: CGPoint(x: 370, y: 134), options: [])
    ctx.setFillColor(rgb(0xFFFFFF, 0.12)); ctx.fill(CGRect(x: 190, y: 34, width: 180, height: 100))
    ctx.restoreGState()
    let play = CGMutablePath(); play.move(to: CGPoint(x: 268, y: 66)); play.addLine(to: CGPoint(x: 300, y: 84)); play.addLine(to: CGPoint(x: 268, y: 102)); play.closeSubpath()
    ctx.addPath(play); ctx.setFillColor(rgb(0xFFFFFF, 0.92)); ctx.fillPath()
    let cone = CGMutablePath()
    cone.addLines(between: [CGPoint(x: 200, y: 134), CGPoint(x: 360, y: 134), CGPoint(x: 250, y: 240), CGPoint(x: 60, y: 240)]); cone.closeSubpath()
    ctx.saveGState(); ctx.addPath(cone); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0x9FC4FF, 0.28)), (1, rgb(0x9FC4FF, 0))]),
                           start: CGPoint(x: 0, y: 134), end: CGPoint(x: 0, y: 240), options: [])
    ctx.restoreGState()
}

/// Goose head and neck (the "Shorter" position), outer edge lit by the screen.
func drawGoose(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.translateBy(x: 18, y: 8); ctx.scaleBy(x: 0.82, y: 0.82)
    let neck = CGMutablePath()
    neck.move(to: CGPoint(x: 86, y: 230))
    neck.addCurve(to: CGPoint(x: 104, y: 124), control1: CGPoint(x: 80, y: 190), control2: CGPoint(x: 84, y: 150))
    neck.addLine(to: CGPoint(x: 124, y: 136))
    neck.addCurve(to: CGPoint(x: 114, y: 230), control1: CGPoint(x: 112, y: 154), control2: CGPoint(x: 110, y: 190))
    neck.closeSubpath()
    let head = CGPath(ellipseIn: CGRect(x: 97, y: 101, width: 38, height: 38), transform: nil)
    let beak = CGMutablePath()
    beak.addLines(between: [CGPoint(x: 130, y: 112), CGPoint(x: 154, y: 118), CGPoint(x: 132, y: 128)]); beak.closeSubpath()
    let shapes: [CGPath] = [neck, head, beak]
    let rim = gradient([(0, rgb(0xC9B0FF)), (0.6, rgb(0x5B8BFF, 0.5)), (1, rgb(0x5B8BFF, 0))])
    // Outline pass: each shape's stroke carries its own top-right → bottom-left gradient.
    for shape in shapes {
        let box = shape.boundingBoxOfPath
        ctx.saveGState()
        ctx.addPath(shape); ctx.setLineWidth(6); ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(rim, start: CGPoint(x: box.maxX, y: box.minY), end: CGPoint(x: box.minX, y: box.maxY), options: [])
        ctx.restoreGState()
    }
    // Fill pass on top hides the inner half of every stroke, leaving only the outer edge lit.
    ctx.setFillColor(rgb(0x15102A))
    for shape in shapes { ctx.addPath(shape); ctx.fillPath() }
    ctx.restoreGState()
}

func drawCouch(_ ctx: CGContext) {
    ctx.setFillColor(rgb(0x1C1636))
    for p in [roundRect(30, 196, 190, 44, 14), roundRect(20, 176, 34, 64, 14), roundRect(196, 176, 34, 64, 14)] {
        ctx.addPath(p); ctx.fillPath()
    }
    ctx.setFillColor(rgb(0x241C44)); ctx.addPath(roundRect(40, 160, 170, 40, 14)); ctx.fillPath()
}

extension CGContext {
    func resetToPixels() { concatenate(ctm.inverted()) }
}

// MARK: - App icon layers

let brand = "App Icon & Top Shelf Image.brandassets"

// MARK: - Top Shelf (scene on the right, wordmark on the left)

func drawText(_ ctx: CGContext, _ text: String, font: String, size: CGFloat, at p: CGPoint,
              color: CGColor? = nil, fill: CGGradient? = nil) -> CGFloat {
    let ctFont = CTFontCreateWithName(font as CFString, size, nil)
    let attr = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color ?? rgb(0xFFFFFF),
        NSAttributedString.Key(kCTKernAttributeName as String): -size * 0.025,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    ctx.saveGState()
    ctx.translateBy(x: p.x, y: p.y); ctx.scaleBy(x: 1, y: -1)   // CoreText draws y-up
    ctx.textPosition = .zero
    if let fill {
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        CTLineDraw(line, ctx)
        ctx.setBlendMode(.sourceIn)
        ctx.drawLinearGradient(fill, start: .zero, end: CGPoint(x: width, y: 0), options: [])
        ctx.endTransparencyLayer()
    } else {
        CTLineDraw(line, ctx)
    }
    ctx.restoreGState()
    return width
}

func textWidth(_ text: String, font: String, size: CGFloat) -> CGFloat {
    let attr = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
        NSAttributedString.Key(kCTKernAttributeName as String): -size * 0.025,
    ])
    return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil))
}

/// Wordmark and scene as one compact group, centered, so nothing hugs the banner's edges
/// (tvOS can crop the sides of the wide banner).
func topShelf(px w: Int, _ h: Int, _ rel: String) {
    let (ctx, s, W) = canvas(px: w, h)
    drawRoom(ctx, width: W)

    let size: CGFloat = 40, gap: CGFloat = 34, k: CGFloat = 0.7
    let wordWidth = textWidth("Jelly", font: "Figtree-SemiBold", size: size)
                  + textWidth("Goose", font: "Figtree-Black", size: size)
    let sceneWidth = 360 * k                       // scene content spans x 20...380
    let left = (W - (wordWidth + gap + sceneWidth)) / 2

    // The banner shows the Movie Night scene rather than the icon's jellyfish:
    // it is wide and sits above everything else on the Home screen, which suits
    // a room with a lit screen better than a single creature.
    let sceneLeft = left + wordWidth + gap
    let scene = CGAffineTransform(translationX: sceneLeft - 20 * k, y: 240 - 240 * k).scaledBy(x: k, y: k)
    drawScreenHalo(ctx, pxPerUnit: s, transform: scene)
    ctx.saveGState(); ctx.concatenate(scene)
    drawScreenAndBeam(ctx); drawGoose(ctx); drawCouch(ctx)
    ctx.restoreGState()

    let baseline: CGFloat = 126
    let jw = drawText(ctx, "Jelly", font: "Figtree-SemiBold", size: size, at: CGPoint(x: left, y: baseline), fill: violet)
    _ = drawText(ctx, "Goose", font: "Figtree-Black", size: size, at: CGPoint(x: left + jw, y: baseline))
    _ = drawText(ctx, "Movies & shows from your own server", font: "Figtree-Medium", size: 11.5,
                 at: CGPoint(x: left + 2, y: baseline + 23), color: rgb(0xFFFFFF, 0.62))
    save(ctx, rel)
}


// MARK: - Alternate icons
//
// Each alternate is a layered image stack of its own, named for the icon. The
// default Movie Night set above stays the primary; these are what Settings →
// Appearance offers instead.

/// Head and neck seen from the side, facing right. Shared by Play Beak and Neon.
func gooseProfile() -> (neck: CGPath, head: CGPath, beak: CGPath) {
    let neck = CGMutablePath()
    neck.move(to: CGPoint(x: 162, y: 244))
    neck.addCurve(to: CGPoint(x: 178, y: 122), control1: CGPoint(x: 153, y: 198), control2: CGPoint(x: 157, y: 150))
    neck.addLine(to: CGPoint(x: 206, y: 134))
    neck.addCurve(to: CGPoint(x: 200, y: 244), control1: CGPoint(x: 196, y: 156), control2: CGPoint(x: 192, y: 198))
    neck.closeSubpath()
    let head = CGPath(ellipseIn: CGRect(x: 168, y: 84, width: 54, height: 52), transform: nil)
    return (neck, head, playTriangle())
}

/// Lays a blurred copy of a shape beneath it, twice over, so its colour spills
/// onto the dark ground the way a lit thing does.
func bloom(_ ctx: CGContext, pxPerUnit s: CGFloat, path: CGPath, color: CGColor,
           sigma: CGFloat = 10, alpha: CGFloat = 0.85) {
    let (glow, _, _) = canvas(px: ctx.width, ctx.height, unitsHigh: CGFloat(ctx.height) / s)
    glow.addPath(path); glow.setFillColor(color); glow.fillPath()
    let ci = CIImage(cgImage: glow.makeImage()!)
    let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: sigma * s).cropped(to: ci.extent)
    let halo = CIContext().createCGImage(blurred, from: ci.extent)!
    ctx.saveGState(); ctx.resetToPixels(); ctx.setAlpha(alpha)
    for _ in 0..<2 { ctx.draw(halo, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)) }
    ctx.restoreGState()
}

/// The play glyph: an equilateral triangle pointing right, `height` tall, its
/// flat side at `x` and centred on `midY`. Every beak in the set is one of
/// these, rounded at the corners by the stroke that paints it — the shape reads
/// as a beak on the animal and as a play button on the shelf.
func playGlyph(x: CGFloat, midY: CGFloat, height: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let half = height / 2
    p.addLines(between: [CGPoint(x: x, y: midY - half),
                         CGPoint(x: x + height * 0.866, y: midY),
                         CGPoint(x: x, y: midY + half)])
    p.closeSubpath()
    return p
}

/// Two thirds the height of the goose's head, starting where the head ends.
func playTriangle() -> CGPath {
    playGlyph(x: 221, midY: 110, height: 32)
}

// MARK: Play Beak

func playBeakMiddle(_ ctx: CGContext) {
    let (neck, head, _) = gooseProfile()
    // A shadow under the bird separates it from the dark room behind.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 20, color: rgb(0x05040F, 0.6))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.addPath(neck); ctx.fillPath()
    ctx.addPath(head); ctx.fillPath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    // Eye, set where the head meets the beak.
    ctx.setFillColor(rgb(0x1A1233))
    ctx.addPath(CGPath(ellipseIn: CGRect(x: 200, y: 102, width: 11, height: 11), transform: nil))
    ctx.fillPath()
}

func playBeakFront(_ ctx: CGContext, pxPerUnit s: CGFloat) {
    let beak = playTriangle()

    // The beak throws light into the room, like the screen in the other icons.
    bloom(ctx, pxPerUnit: s, path: beak, color: rgb(0xFFA132))

    // Fill, then stroke the same path to round its corners.
    ctx.saveGState(); ctx.addPath(beak); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xFFC24A)), (1, rgb(0xF08A12))]),
                           start: CGPoint(x: 221, y: 94), end: CGPoint(x: 250, y: 126), options: [])
    ctx.restoreGState()
    ctx.addPath(beak)
    ctx.setStrokeColor(rgb(0xF9A82E)); ctx.setLineWidth(5); ctx.setLineJoin(.round)
    ctx.strokePath()
}

// MARK: Jellygoose
//
// The side-on jellyfish with a goose's eye and beak: a smooth bell with a
// scalloped hem, a highlight where the light sits, and strands hanging straight
// down. Neon Sign below is the same creature drawn as tubing.

/// The bell: a dome spanning x 129…274, its crown at y 53 and its hem at 145,
/// finished with four shallow scallops. Those are the mockup's proportions —
/// a taller bell crowds the tentacles and the whole animal reads squat.
func jellyBell() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 129, y: 145))
    p.addCurve(to: CGPoint(x: 274, y: 145), control1: CGPoint(x: 129, y: 22), control2: CGPoint(x: 274, y: 22))
    var x: CGFloat = 274
    while x > 129 {
        let next = x - 36.25
        p.addCurve(to: CGPoint(x: next, y: 145),
                   control1: CGPoint(x: x - 10, y: 156), control2: CGPoint(x: next + 10, y: 156))
        x = next
    }
    p.closeSubpath()
    return p
}

/// Five strands, each a slow S, hanging about as far as the bell is tall.
func jellyTentacles() -> [CGPath] {
    let lengths: [CGFloat] = [222, 232, 238, 230, 216]
    return zip([150, 175, 200, 225, 250], lengths).map { x, bottom in
        let sx = CGFloat(x)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: sx, y: 148))
        p.addCurve(to: CGPoint(x: sx, y: (148 + bottom) / 2),
                   control1: CGPoint(x: sx - 10, y: 172), control2: CGPoint(x: sx + 10, y: 184))
        p.addCurve(to: CGPoint(x: sx - 3, y: bottom),
                   control1: CGPoint(x: sx - 9, y: bottom - 26), control2: CGPoint(x: sx + 7, y: bottom - 12))
        return p
    }
}

func jellygooseBack(_ ctx: CGContext, width W: CGFloat, height H: CGFloat = 240) {
    ctx.saveGState()
    ctx.addRect(CGRect(x: 0, y: 0, width: W, height: H)); ctx.clip()
    ctx.setFillColor(rgb(0x070A16)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.translateBy(x: W * 0.62, y: H * 0.18); ctx.scaleBy(x: 1, y: H / W)
    ctx.drawRadialGradient(gradient([(0, rgb(0x1B2550)), (0.6, rgb(0x121A38, 0.7)), (1, rgb(0x070A16, 0))]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: W * 0.75, options: [])
    ctx.restoreGState()

    // Bubbles, kept near the middle so wide banners don't strand them at the edges.
    for (x, y, r, a) in [(96, 74, 5, 0.30), (118, 168, 4, 0.22), (74, 126, 3, 0.18), (300, 96, 6, 0.28),
                         (322, 176, 4, 0.20), (286, 46, 3, 0.22), (146, 40, 3, 0.20), (258, 30, 4, 0.18)]
                        as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        let cx = W / 2 + (x - 200)
        ctx.setFillColor(rgb(0x7FA6D8, a))
        ctx.addPath(CGPath(ellipseIn: CGRect(x: cx - r, y: y - r, width: r * 2, height: r * 2), transform: nil))
        ctx.fillPath()
    }
}

func jellygooseMiddle(_ ctx: CGContext, pxPerUnit s: CGFloat) {
    let bell = jellyBell()

    // A glow under the bell, so it reads as lit from inside.
    let (glow, _, _) = canvas(px: ctx.width, ctx.height, unitsHigh: CGFloat(ctx.height) / s)
    glow.addPath(bell); glow.clip()
    glow.drawLinearGradient(violet, start: CGPoint(x: 126, y: 40), end: CGPoint(x: 274, y: 160), options: [])
    let ci = CIImage(cgImage: glow.makeImage()!)
    let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: 14 * s).cropped(to: ci.extent)
    ctx.saveGState(); ctx.resetToPixels(); ctx.setAlpha(0.7)
    ctx.draw(CIContext().createCGImage(blurred, from: ci.extent)!,
             in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    ctx.restoreGState()

    ctx.saveGState(); ctx.addPath(bell); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xA98CFF)), (0.45, rgb(0x8A6BF2)), (1, rgb(0x6A5BE0))]),
                           start: CGPoint(x: 150, y: 44), end: CGPoint(x: 250, y: 162), options: [])
    ctx.restoreGState()

    // The light on the shoulder of the bell, tilted the way the dome turns and
    // clipped to it, so none of it spills past the edge.
    ctx.saveGState()
    ctx.addPath(bell); ctx.clip()
    ctx.translateBy(x: 170, y: 82); ctx.rotate(by: -0.42)
    ctx.addPath(CGPath(ellipseIn: CGRect(x: -29, y: -13, width: 58, height: 26), transform: nil)); ctx.clip()
    ctx.drawRadialGradient(gradient([(0, rgb(0xFFFFFF, 0.55)), (0.7, rgb(0xFFFFFF, 0.16)), (1, rgb(0xFFFFFF, 0))]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 34, options: [])
    ctx.restoreGState()

    // Eye and beak: the goose half of the animal.
    ctx.setFillColor(rgb(0x12102A))
    ctx.addPath(CGPath(ellipseIn: CGRect(x: 216, y: 91, width: 16, height: 16), transform: nil)); ctx.fillPath()
    ctx.setFillColor(rgb(0xFFFFFF, 0.92))
    ctx.addPath(CGPath(ellipseIn: CGRect(x: 220, y: 94, width: 5, height: 5), transform: nil)); ctx.fillPath()

    let beak = playGlyph(x: 264, midY: 116, height: 38)
    ctx.saveGState(); ctx.addPath(beak); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xFFC24A)), (1, rgb(0xEE8412))]),
                           start: CGPoint(x: 264, y: 97), end: CGPoint(x: 297, y: 135), options: [])
    ctx.restoreGState()
    ctx.addPath(beak)
    ctx.setStrokeColor(rgb(0xF9A82E)); ctx.setLineWidth(5); ctx.setLineJoin(.round)
    ctx.strokePath()
}

func jellygooseFront(_ ctx: CGContext) {
    let fade = gradient([(0, rgb(0xB49BFF, 0.95)), (0.5, rgb(0x8FA9F0, 0.6)), (1, rgb(0x5E86C8, 0.12))])
    for path in jellyTentacles() {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(4); ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(fade, start: CGPoint(x: 0, y: 150), end: CGPoint(x: 0, y: 236), options: [])
        ctx.restoreGState()
    }
}

// MARK: Neon Sign

func neonBack(_ ctx: CGContext, width W: CGFloat, height H: CGFloat = 240) {
    ctx.setFillColor(rgb(0x05050A)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.saveGState()
    ctx.translateBy(x: W * 0.5, y: H * 0.5); ctx.scaleBy(x: 1, y: H / W)
    ctx.drawRadialGradient(gradient([(0, rgb(0x241053, 0.8)), (1, rgb(0x05050A, 0))]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: W * 0.45, options: [])
    ctx.restoreGState()
}

/// Stroked paths drawn twice: a wide blurred pass for the halo, a thin bright one
/// on top, which is what makes a line look like a lit tube.
func neonStroke(_ ctx: CGContext, pxPerUnit s: CGFloat, paths: [CGPath], color: CGColor, width: CGFloat,
                passes: Int = 2) {
    let (halo, _, _) = canvas(px: ctx.width, ctx.height, unitsHigh: CGFloat(ctx.height) / s)
    halo.setStrokeColor(color); halo.setLineWidth(width); halo.setLineJoin(.round); halo.setLineCap(.round)
    for p in paths { halo.addPath(p) }
    halo.strokePath()
    let ci = CIImage(cgImage: halo.makeImage()!)
    let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: 8 * s).cropped(to: ci.extent)
    let image = CIContext().createCGImage(blurred, from: ci.extent)!
    ctx.saveGState(); ctx.resetToPixels()
    for _ in 0..<passes { ctx.draw(image, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)) }
    ctx.restoreGState()

    ctx.setStrokeColor(rgb(0xFFFFFF, 0.95)); ctx.setLineWidth(width * 0.40)
    ctx.setLineJoin(.round); ctx.setLineCap(.round)
    for p in paths { ctx.addPath(p) }
    ctx.strokePath()
}

func neonMiddle(_ ctx: CGContext, pxPerUnit s: CGFloat) {
    neonStroke(ctx, pxPerUnit: s, paths: [jellyBell()], color: rgb(0xA46BFF), width: 9)
    // The eye is a ring, the way a neon sign would draw one.
    let eye = CGPath(ellipseIn: CGRect(x: 217, y: 92, width: 14, height: 14), transform: nil)
    neonStroke(ctx, pxPerUnit: s, paths: [eye], color: rgb(0xA46BFF), width: 6, passes: 1)
}

func neonFront(_ ctx: CGContext, pxPerUnit s: CGFloat) {
    let fade = gradient([(0, rgb(0xB49BFF, 0.9)), (1, rgb(0x5E86C8, 0.15))])
    for path in jellyTentacles() {
        ctx.saveGState()
        ctx.addPath(path); ctx.setLineWidth(3.5); ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(fade, start: CGPoint(x: 0, y: 150), end: CGPoint(x: 0, y: 236), options: [])
        ctx.restoreGState()
    }
    // Out at the bell's edge: drawn as tubing, an overlap shows as crossed lines.
    neonStroke(ctx, pxPerUnit: s, paths: [playGlyph(x: 269, midY: 116, height: 36)],
               color: rgb(0xFFA032), width: 7)
}

// MARK: Play Tile and Marquee
//
// The mark from jellygoose.app: a violet-to-blue tile with a white play glyph.
// Play Tile is the tile glowing on the site's near-black; Marquee blows it up
// until the gradient is the whole icon and the glyph is all that sits on it.

/// The site's background: near-black, with a faint violet light in the middle.
func siteBack(_ ctx: CGContext, width W: CGFloat, height H: CGFloat = 240) {
    ctx.setFillColor(rgb(0x0D0D14)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.saveGState()
    ctx.translateBy(x: W / 2, y: H / 2); ctx.scaleBy(x: 1, y: (H * 0.7) / (W * 0.6))
    ctx.drawRadialGradient(gradient([(0, rgb(0x7A45E6, 0.22)), (0.7, rgb(0x7A45E6, 0))]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: W * 0.6, options: [])
    ctx.restoreGState()
}

/// The gradient tile, with the violet glow the site gives it.
func siteTile(_ ctx: CGContext, pxPerUnit s: CGFloat, box: CGRect) {
    let tile = roundRect(box.minX, box.minY, box.width, box.height, box.width / 4)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: box.width * 0.5 * s, color: rgb(0x7A45E6, 0.55))
    ctx.setFillColor(rgb(0x7A45E6)); ctx.addPath(tile); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(tile); ctx.clip()
    ctx.drawLinearGradient(violet, start: box.origin, end: CGPoint(x: box.maxX, y: box.maxY), options: [])
    ctx.restoreGState()
}

/// The site's play glyph (25,19 → 45,32 → 25,45 in a 64-unit tile), in white.
func siteGlyph(_ ctx: CGContext, box: CGRect) {
    let k = box.width / 64
    let play = CGMutablePath()
    play.addLines(between: [CGPoint(x: box.minX + 25 * k, y: box.minY + 19 * k),
                            CGPoint(x: box.minX + 45 * k, y: box.minY + 32 * k),
                            CGPoint(x: box.minX + 25 * k, y: box.minY + 45 * k)])
    play.closeSubpath()
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.addPath(play); ctx.fillPath()
}

let playTileBox = CGRect(x: 140, y: 60, width: 120, height: 120)

/// Marquee's glyph box: the same glyph, 210 units across, centred.
let marqueeBox = CGRect(x: 95, y: 15, width: 210, height: 210)

func marqueeBack(_ ctx: CGContext, width W: CGFloat, height H: CGFloat = 240) {
    ctx.drawLinearGradient(violet, start: .zero, end: CGPoint(x: W, y: H), options: [])
}

/// The glyph, lifted off the gradient by a soft shadow below it.
func marqueeFront(_ ctx: CGContext, pxPerUnit s: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 14 * s, color: rgb(0x0D0D14, 0.35))
    siteGlyph(ctx, box: marqueeBox)
    ctx.restoreGState()
}

// MARK: - Writing the alternates

struct IconDesign {
    /// The image stack's name, and what the app passes to tvOS. No spaces: the
    /// build setting that lists the alternates separates them by spaces.
    let name: String
    let slug: String            // what the flat preview is filed under
    let back: (CGContext, CGFloat, CGFloat) -> Void    // ctx, px-per-unit, width in units
    let middle: (CGContext, CGFloat) -> Void
    let front: (CGContext, CGFloat) -> Void
}

/// The default: the jellyfish wearing a goose's eye and beak, which is what the
/// app is called. It goes in the brand assets rather than beside the alternates.
let defaultDesign = IconDesign(
    name: "App Icon", slug: "jellygoose",
    back: { ctx, _, w in jellygooseBack(ctx, width: w) },
    middle: { ctx, s in jellygooseMiddle(ctx, pxPerUnit: s) },
    front: { ctx, _ in jellygooseFront(ctx) })

let alternates = [
    IconDesign(name: "MovieNight", slug: "movie-night",
               back: { ctx, s, w in
                   drawRoom(ctx, width: w)
                   drawScreenHalo(ctx, pxPerUnit: s, transform: .identity)
                   drawScreenAndBeam(ctx)
               },
               middle: { ctx, _ in drawGoose(ctx) },
               front: { ctx, _ in drawCouch(ctx) }),
    IconDesign(name: "PlayBeak", slug: "play-beak",
               back: { ctx, _, w in drawRoom(ctx, width: w) },
               middle: { ctx, _ in playBeakMiddle(ctx) },
               front: { ctx, s in playBeakFront(ctx, pxPerUnit: s) }),
    IconDesign(name: "PlayTile", slug: "play-tile",
               back: { ctx, _, w in siteBack(ctx, width: w) },
               middle: { ctx, s in siteTile(ctx, pxPerUnit: s, box: playTileBox) },
               front: { ctx, _ in siteGlyph(ctx, box: playTileBox) }),
    IconDesign(name: "Marquee", slug: "marquee",
               back: { ctx, _, w in marqueeBack(ctx, width: w) },
               middle: { _, _ in },
               front: { ctx, s in marqueeFront(ctx, pxPerUnit: s) }),
    IconDesign(name: "Neon", slug: "neon",
               back: { ctx, _, w in neonBack(ctx, width: w) },
               middle: { ctx, s in neonMiddle(ctx, pxPerUnit: s) },
               front: { ctx, s in neonFront(ctx, pxPerUnit: s) }),
]

func writeLayer(_ dir: String, _ layer: String, _ file: String, px w: Int, _ h: Int,
                _ draw: (CGContext, CGFloat, CGFloat) -> Void) {
    let (ctx, s, W) = canvas(px: w, h)
    draw(ctx, s, W)
    save(ctx, "\(dir)/\(layer).imagestacklayer/Content.imageset/\(file).png")
}

for design in alternates {
    let stack = "\(design.name).imagestack"
    for (px, suffix) in [(400, ""), (800, "@2x")] {
        let h = px * 240 / 400
        writeLayer(stack, "Back", "back\(suffix)", px: px, h) { ctx, s, w in design.back(ctx, s, w) }
        writeLayer(stack, "Middle", "middle\(suffix)", px: px, h) { ctx, s, _ in design.middle(ctx, s) }
        writeLayer(stack, "Front", "front\(suffix)", px: px, h) { ctx, s, _ in design.front(ctx, s) }
    }
}

// MARK: - Flat previews for the picker in Settings

/// The layers drawn into one image, since a stack can't be shown in SwiftUI.
func preview(_ rel: String, px w: Int, _ h: Int, _ draw: (CGContext, CGFloat, CGFloat) -> Void) {
    let (ctx, s, W) = canvas(px: w, h)
    draw(ctx, s, W)
    save(ctx, rel)
}

for (px, suffix) in [(400, ""), (800, "@2x")] {
    let h = px * 240 / 400
    for design in [defaultDesign] + alternates {
        preview("Icon Previews/\(design.slug).imageset/\(design.slug)\(suffix).png", px: px, h) { ctx, s, w in
            design.back(ctx, s, w); design.middle(ctx, s); design.front(ctx, s)
        }
    }
}

// MARK: - Asset catalog metadata
//
// The PNGs above are only half of an asset: each folder needs the Contents.json
// that tells actool what it's looking at.

func writeJSON(_ rel: String, _ body: String) {
    let url = outDir.appendingPathComponent(rel)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? body.data(using: .utf8)!.write(to: url)
}

let info = #""info": { "author": "xcode", "version": 1 }"#

func imagesetJSON(_ rel: String, base: String) {
    writeJSON(rel, """
    {
      \(info),
      "images": [
        { "filename": "\(base).png", "idiom": "tv", "scale": "1x" },
        { "filename": "\(base)@2x.png", "idiom": "tv", "scale": "2x" }
      ]
    }
    """)
}

for design in alternates {
    let stack = "\(design.name).imagestack"
    writeJSON("\(stack)/Contents.json", """
    {
      \(info),
      "layers": [
        { "filename": "Front.imagestacklayer" },
        { "filename": "Middle.imagestacklayer" },
        { "filename": "Back.imagestacklayer" }
      ]
    }
    """)
    for (layer, base) in [("Back", "back"), ("Middle", "middle"), ("Front", "front")] {
        writeJSON("\(stack)/\(layer).imagestacklayer/Contents.json", "{ \(info) }")
        imagesetJSON("\(stack)/\(layer).imagestacklayer/Content.imageset/Contents.json", base: base)
    }
}

writeJSON("Icon Previews/Contents.json", "{ \(info) }")
for slug in ([defaultDesign] + alternates).map(\.slug) {
    imagesetJSON("Icon Previews/\(slug).imageset/Contents.json", base: slug)
}

// MARK: - The default icon's brand assets
//
// The app's own icon, the one the App Store shows, and the Top Shelf banner, all
// drawn from the default design. Written last, so everything it needs is defined.

func brandIcon(px w: Int, _ h: Int, into dir: String, suffix: String) {
    for (layer, base, draw) in [
        ("Back", "back", { (c: CGContext, s: CGFloat, width: CGFloat) in defaultDesign.back(c, s, width) }),
        ("Middle", "middle", { c, s, _ in defaultDesign.middle(c, s) }),
        ("Front", "front", { c, s, _ in defaultDesign.front(c, s) }),
    ] {
        let (ctx, s, W) = canvas(px: w, h)
        draw(ctx, s, W)
        save(ctx, "\(dir)/\(layer).imagestacklayer/Content.imageset/\(base)\(suffix).png")
    }
}

brandIcon(px: 400, 240, into: "\(brand)/App Icon.imagestack", suffix: "")
brandIcon(px: 800, 480, into: "\(brand)/App Icon.imagestack", suffix: "@2x")
brandIcon(px: 1280, 768, into: "\(brand)/App Icon - App Store.imagestack", suffix: "")

topShelf(px: 1920, 720, "\(brand)/Top Shelf Image.imageset/top-shelf.png")
topShelf(px: 3840, 1440, "\(brand)/Top Shelf Image.imageset/top-shelf@2x.png")
topShelf(px: 2320, 720, "\(brand)/Top Shelf Image Wide.imageset/top-shelf-wide.png")
topShelf(px: 4640, 1440, "\(brand)/Top Shelf Image Wide.imageset/top-shelf-wide@2x.png")
