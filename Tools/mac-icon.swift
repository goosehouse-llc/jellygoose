// The Mac's app icon from the iPhone's square artwork: since Big Sur a Mac icon is a rounded
// square drawn inside its canvas (824 of 1024, a soft shadow under it), not a full-bleed square
// the system masks. Writes every size an appiconset needs, and its Contents.json.
//
//   swift Tools/mac-icon.swift iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png macOS/Assets.xcassets/MacAppIcon.appiconset
import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]),
      let art = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: mac-icon <1024 png> <appiconset folder>"); exit(1)
}
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    // The shadow, cast by the shape.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0.05, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    // The artwork, inside the shape.
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.draw(art, in: body)
    ctx.restoreGState()
    // A faint edge, as Apple's icons have.
    ctx.addPath(shape); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08)); ctx.setLineWidth(2); ctx.strokePath()
    return ctx.makeImage()!
}

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "mac-\(size)@\(scale)x.png"
        let dest = CGImageDestinationCreateWithURL(outDir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, render(size * scale), nil)
        CGImageDestinationFinalize(dest)
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(outDir.path)")
