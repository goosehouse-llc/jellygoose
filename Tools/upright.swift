// A screenshot of an iPhone or iPad on its side comes out of XCUIScreen as the
// upright picture with a note to turn it. Previews honour the note; the App
// Store draws the pixels as they are. This turns the pixels:
//
//   swiftc -O Tools/upright.swift -o /tmp/upright && /tmp/upright in.png out.png
import Foundation
import ImageIO
import UniformTypeIdentifiers
let args = CommandLine.arguments
guard args.count == 3, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil) else { exit(1) }
let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: max(w, h)]
guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
      let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(2) }
CGImageDestinationAddImage(out, image, nil)
exit(CGImageDestinationFinalize(out) ? 0 : 3)
