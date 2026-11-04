// A made-up film's title logo, on a transparent ground: the words in Figtree Black, spaced,
// filled with a lantern-warm gradient and a soft glow, trimmed to what's drawn.
// usage: swift logo.swift <Fonts folder> <out.png> "LANTERN BAY"
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: args[1]).appendingPathComponent("Figtree-Black.ttf") as CFURL, .process, nil)
let text = args[3]
let size: CGFloat = 220, pad: CGFloat = 80
let font = CTFontCreateWithName("Figtree-Black" as CFString, size, nil)
let attr = NSAttributedString(string: text, attributes: [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTKernAttributeName as String): size * 0.06,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
])
let line = CTLineCreateWithAttributedString(attr)
var ascent: CGFloat = 0, descent: CGFloat = 0
let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
let W = Int(width + pad * 2), H = Int(ascent + descent + pad * 2)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let base = CGPoint(x: pad, y: pad + descent)
// The glow: the words drawn once in amber with a wide shadow.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 46, color: rgb(0xFF9F43, 0.75))
ctx.textPosition = base
let glowAttr = NSMutableAttributedString(attributedString: attr)
glowAttr.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: rgb(0xFFB35C, 0.9), range: NSRange(location: 0, length: glowAttr.length))
CTLineDraw(CTLineCreateWithAttributedString(glowAttr), ctx)
ctx.restoreGState()
// The words, filled top to bottom from pale gold to lantern orange.
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.textPosition = base
CTLineDraw(line, ctx)
ctx.setBlendMode(.sourceIn)
let g = CGGradient(colorsSpace: space, colors: [rgb(0xFFF6DA), rgb(0xFFD58A), rgb(0xFF9A4A)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: base.y + ascent), end: CGPoint(x: 0, y: base.y - descent), options: [])
ctx.endTransparencyLayer()
let url = URL(fileURLWithPath: args[2])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("logo \(W)x\(H)")
