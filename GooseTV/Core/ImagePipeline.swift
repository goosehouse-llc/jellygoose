#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import ImageIO
import CoreImage

/// Artwork loader with real caching, replacing AsyncImage (whose shared URL
/// cache is tiny and which re-fetches whenever a grid cell recycles).
/// Decoded images live in an NSCache; encoded bytes persist in a large URLCache.
/// Trickplay sheets, decoded whole and kept: a frame is cut from one each time
/// the scrub mark moves, and the pipeline's downsampling would blur them.
enum TrickplaySheets {
    nonisolated(unsafe) private static let cache: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.totalCostLimit = 64 << 20   // a few sheets; one is ~23 MB decoded
        return cache
    }()

    /// The sheets as the server sent them, about a megabyte each: a whole film's
    /// worth fits here, where decoded they'd be twenty times the size.
    nonisolated(unsafe) private static let encoded: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.totalCostLimit = 48 << 20
        return cache
    }()

    static func cached(_ url: URL) -> CGImage? { cache.object(forKey: url as NSURL) }

    /// One fetch and one decode per sheet, however many ask: a scrub moves
    /// the mark faster than a sheet arrives, and each move asked again, so a
    /// sheet not yet here was downloaded and decoded (~23 MB) several times
    /// over, alongside the same bytes on their way for the prefetch.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fetches: [URL: Task<Data?, Never>] = [:]
    nonisolated(unsafe) private static var decodes: [URL: Task<CGImage?, Never>] = [:]

    private static func bytes(_ url: URL) async -> Data? {
        if let hit = encoded.object(forKey: url as NSURL) { return hit as Data }
        return await fetchTask(for: url).value
    }

    /// The fetch on its way for this sheet, or a new one. Synchronous, so the
    /// lock is never held across a suspension point.
    private static func fetchTask(for url: URL) -> Task<Data?, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let running = fetches[url] { return running }
        let task = Task<Data?, Never> {
            let data = try? await URLSession.shared.data(from: url).0
            if let data { encoded.setObject(data as NSData, forKey: url as NSURL, cost: data.count) }
            lock.withLock { fetches[url] = nil }
            return data
        }
        fetches[url] = task
        return task
    }

    private static func decodeTask(for url: URL) -> Task<CGImage?, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let running = decodes[url] { return running }
        let task = Task<CGImage?, Never> {
            let image = await decode(url)
            lock.withLock { decodes[url] = nil }
            return image
        }
        decodes[url] = task
        return task
    }

    /// Fetches a film's sheets ahead of any scrubbing, nearest the given one
    /// first, two at a time and after a pause, so they don't compete with the
    /// film starting. Only fetched: each is decoded when a scrub reaches it.
    /// Run from the controls' own task, so closing the player or moving on to
    /// another episode stops it, rather than leaving it fetching a film nobody
    /// is watching any more.
    static func prefetch(_ urls: [URL], near index: Int) async {
        guard !urls.isEmpty else { return }
        let order = urls.indices.sorted { abs($0 - index) < abs($1 - index) }.map { urls[$0] }
        try? await Task.sleep(for: .seconds(5))
        for start in stride(from: 0, to: order.count, by: 2) {
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                for url in order[start..<min(start + 2, order.count)] {
                    group.addTask { _ = await bytes(url) }
                }
            }
        }
    }

    /// Nonisolated-async, so the decode runs off the main actor.
    static func load(_ url: URL) async -> CGImage? {
        if let hit = cached(url) { return hit }
        return await decodeTask(for: url).value
    }

    private static func decode(_ url: URL) async -> CGImage? {
        guard let data = await bytes(url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        cache.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        return image
    }
}

enum ImagePipeline {
    /// The decode is capped at the width the url asked the server for, or at
    /// this for anything smaller: its longest side, so a poster asked for 440
    /// wide keeps its 660 of height. Not much more: an episode still asked for
    /// at 800 was decoded at 1280, over twice the memory, and a season's worth
    /// pushed the page's own backdrop out of the cache while it was on screen. A backdrop drawn across the screen asks
    /// for the screen's own pixels, which on a 4K Apple TV is 3840; capping
    /// that at 1280 was what made the detail page's backdrop look grainy.
    private static let minPixelSize = 960
    private static let maxPixelSize = 3840

    private static func pixelSize(for url: URL) -> CGFloat {
        let asked = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "maxWidth" }?.value.flatMap(Int.init) ?? 0
        return CGFloat(min(max(asked, minPixelSize), maxPixelSize))
    }

    private static let memory: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 192 << 20   // decoded bytes
        return cache
    }()

    /// NSCache empties itself under memory pressure, which on a TV happens while
    /// you are still looking at the pictures: scrolling back up the home screen
    /// found the hero and the first cards gone, and watched them reload. These
    /// strong references keep the most recent artwork alive regardless.
    /// Budgeted by bytes, not by count: a home screen holds a hundred small
    /// posters or a handful of backdrops, and counting them treats those alike.
    private static let keptBudget = 120 << 20
    private static let keptLock = NSLock()      // loads finish off the main actor
    private struct Kept {
        let image: UIImage
        let bytes: Int
        /// When it was last asked for, on the counter below.
        var used: UInt64
    }
    private static var kept: [URL: Kept] = [:]
    private static var keptBytes = 0
    private static var uses: UInt64 = 0

    private static func bytes(_ image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    }

    private static func keep(_ image: UIImage, bytes: Int, for url: URL) {
        keptLock.lock()
        defer { keptLock.unlock() }
        uses += 1
        if let replaced = kept.updateValue(Kept(image: image, bytes: bytes, used: uses), forKey: url) {
            keptBytes -= replaced.bytes
        }
        keptBytes += bytes
        // The least recently asked for goes first. A scan of the table, but
        // only when a load pushes it over budget, off the main actor.
        while keptBytes > keptBudget, let oldest = kept.min(by: { $0.value.used < $1.value.used }) {
            kept[oldest.key] = nil
            keptBytes -= oldest.value.bytes
        }
    }

    /// Reading also marks the image as recently used, so what is on screen is
    /// the last thing dropped. Every cell asks on the main thread as it is
    /// made, so this is a lookup and a counter, nothing that walks the table.
    private static func keptImage(_ url: URL) -> UIImage? {
        keptLock.lock()
        defer { keptLock.unlock() }
        guard let entry = kept[url] else { return nil }
        uses += 1
        kept[url]?.used = uses
        return entry.image
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// Synchronous memory-cache hit, so recycled cells repaint without a
    /// placeholder flash.
    static func cached(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        return keptImage(url) ?? memory.object(forKey: url as NSURL)
    }

    /// One fetch per URL however many cells ask. An episode shelf whose stills
    /// all fall back to the series poster was fetching and decoding the same
    /// image once per card, in parallel, before any of them could hit the cache.
    private static let inFlightLock = NSLock()
    private static var inFlight: [URL: Task<UIImage?, Never>] = [:]

    /// Fetches, decodes, and caches; nil on any failure. Nonisolated-async, so
    /// the decode runs off the caller's (main) actor.
    static func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        return await loadTask(for: url).value
    }

    /// The in-flight load for this URL, or a new one. Synchronous, so the lock
    /// is taken and released with no suspension point in between.
    private static func loadTask(for url: URL) -> Task<UIImage?, Never> {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        if let running = inFlight[url] { return running }
        let task = Task<UIImage?, Never> {
            let image = await fetchAndCache(url)
            clearInFlight(url)
            return image
        }
        inFlight[url] = task
        return task
    }

    private static func fetchAndCache(_ url: URL) async -> UIImage? {
        guard let (data, _) = try? await session.data(from: url),
              let image = downsampled(data, maxPixelSize: pixelSize(for: url)) else { return nil }
        let cost = bytes(image)
        memory.setObject(image, forKey: url as NSURL, cost: cost)
        keep(image, bytes: cost, for: url)
        return image
    }

    /// Fetches pictures about to be wanted into the URL cache, undecoded: a
    /// show's episode stills, so holding the remote along the row finds them
    /// on the device rather than waiting on the server card by card. A few at
    /// a time, at low priority, and nothing decoded until a card asks.
    static func prefetch(_ urls: [URL]) {
        let urls = notYetFetched(urls)
        guard !urls.isEmpty else { return }
        let session = session
        Task.detached(priority: .utility) {
            for start in stride(from: 0, to: urls.count, by: 4) {
                await withTaskGroup(of: Void.self) { group in
                    for url in urls[start..<min(start + 4, urls.count)] where cached(url) == nil {
                        group.addTask { _ = try? await session.data(from: url) }
                    }
                }
            }
        }
    }

    private static let prefetchLock = NSLock()
    private static var prefetched: Set<URL> = []

    /// Those not fetched ahead before, and not already in hand as a picture
    /// (a Home backdrop's is kept faded, apart from the rest). Home asks for
    /// a row's pictures on every move up or down, and each time read every
    /// one of them back out of the URL cache for nothing.
    private static func notYetFetched(_ urls: [URL]) -> [URL] {
        prefetchLock.lock()
        defer { prefetchLock.unlock() }
        // Forgotten now and then, so what the URL cache has since let go of
        // is fetched again when next wanted ahead.
        if prefetched.count > 2000 { prefetched.removeAll() }
        return urls.filter { url in
            cached(url) == nil && spotlightCache.object(forKey: url as NSURL) == nil
                && prefetched.insert(url).inserted
        }
    }

    private static func clearInFlight(_ url: URL) {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        inFlight[url] = nil
    }

    /// ImageIO thumbnail decode: caps oversized sources and hands back an
    /// already-decoded bitmap, keeping decompression off the render path.
    private static func downsampled(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

extension ImagePipeline {
    /// Backdrops for the Apple TV's Home, with their fade into the page baked
    /// in. Kept apart from the pipeline's own cache: each is a screen's worth
    /// of pixels, and only the one showing and those a press away are wanted.
    private static let spotlightCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 128 << 20
        return cache
    }()
    private static let spotlightLock = NSLock()
    private static var spotlightInFlight: [URL: Task<UIImage?, Never>] = [:]

    /// A backdrop that fades in from the left and out towards the bottom.
    /// Faded here, once, rather than with a gradient mask on screen, which the
    /// TV would redraw off screen on every frame that anything in front of the
    /// picture moved (a first-generation Apple TV 4K shows that as stutter).
    static func spotlightBackdrop(_ url: URL) async -> UIImage? {
        if let hit = spotlightCache.object(forKey: url as NSURL) { return hit }
        return await spotlightTask(for: url).value
    }

    /// One fade per picture: one made ready ahead and then asked for while
    /// still in hand is waited for, not made twice.
    private static func spotlightTask(for url: URL) -> Task<UIImage?, Never> {
        spotlightLock.lock()
        defer { spotlightLock.unlock() }
        if let running = spotlightInFlight[url] { return running }
        let task = Task<UIImage?, Never> {
            var image: UIImage?
            if let (data, _) = try? await session.data(from: url),
               let faded = isCover(url) ? coverBackdrop(data, maxPixelSize: pixelSize(for: url))
                                        : fadedBackdrop(data, maxPixelSize: pixelSize(for: url)) {
                spotlightCache.setObject(faded, forKey: url as NSURL, cost: bytes(faded))
                image = faded
            }
            clearSpotlightInFlight(url)
            return image
        }
        spotlightInFlight[url] = task
        return task
    }

    /// Synchronous, so the lock is taken and released with no suspension point
    /// in between.
    private static func clearSpotlightInFlight(_ url: URL) {
        spotlightLock.lock()
        defer { spotlightLock.unlock() }
        spotlightInFlight[url] = nil
    }

    private static func fadedBackdrop(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = downsampled(data, maxPixelSize: maxPixelSize)?.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let width = CGFloat(source.width), height = CGFloat(source.height)
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        fade(context, space: space, width: width, height: height)
        return context.makeImage().map { UIImage(cgImage: $0) }
    }

    /// A picture's address marked as a cover: the picture of a recording,
    /// which is no backdrop (the guide's 4:3 of the programme, or a frame),
    /// to be made into one for the top of Home. The mark is the address's
    /// fragment, which is never sent, and keeps the two apart in the cache.
    static func asCover(_ url: URL) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = "cover"
        return parts?.url ?? url
    }

    private static func isCover(_ url: URL) -> Bool { url.fragment == "cover" }

    /// A backdrop made of a cover: the cover out of focus across the whole of
    /// it, faded as any backdrop is, and the cover itself, whole, in the top
    /// right corner clear of the title's words and the rows.
    private static func coverBackdrop(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let width: CGFloat = 1920, height: CGFloat = 1080
        guard let source = downsampled(data, maxPixelSize: maxPixelSize)?.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let backing = blurred(source) else { return nil }
        let shape = CGFloat(source.width) / CGFloat(source.height)
        // Filling the 16:9 of it, cut top and bottom or at the sides.
        let fill = shape > width / height
            ? CGRect(x: (width - height * shape) / 2, y: 0, width: height * shape, height: height)
            : CGRect(x: 0, y: (height - width / shape) / 2, width: width, height: width / shape)
        context.interpolationQuality = .high
        context.draw(backing, in: fill)
        context.setFillColor(CGColor(colorSpace: space, components: [0, 0, 0, 0.3])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        fade(context, space: space, width: width, height: height)
        // The cover: 80 points in from the right and 43 down on a screen
        // 1382 by 778 of them, two thirds of its height, still clear of the
        // title's words and the rows.
        context.setBlendMode(.normal)
        let cardHeight = height * 0.64, cardWidth = min(cardHeight * shape, width * 0.62)
        let card = CGRect(x: width - width * 0.058 - cardWidth, y: height - height * 0.055 - cardHeight,
                          width: cardWidth, height: cardWidth / shape)
        let outline = CGPath(roundedRect: card, cornerWidth: height * 0.023, cornerHeight: height * 0.023, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40,
                          color: CGColor(colorSpace: space, components: [0, 0, 0, 0.5]))
        context.addPath(outline)
        context.setFillColor(CGColor(colorSpace: space, components: [0, 0, 0, 1])!)
        context.fillPath()
        context.restoreGState()
        context.addPath(outline)
        context.clip()
        context.draw(source, in: card)
        return context.makeImage().map { UIImage(cgImage: $0) }
    }

    private static let filters = CIContext(options: [.cacheIntermediates: false])

    /// A picture well out of focus, its edges held so they don't fade to nothing.
    private static func blurred(_ source: CGImage) -> CGImage? {
        let picture = CIImage(cgImage: source)
        let soft = picture.clampedToExtent().applyingGaussianBlur(sigma: Double(source.width) / 16)
        return filters.createCGImage(soft, from: picture.extent)
    }

    /// A backdrop's fade into the page, on what's drawn so far.
    private static func fade(_ context: CGContext, space: CGColorSpace, width: CGFloat, height: CGFloat) {
        // Each ramp keeps the picture where it's opaque and drops it where it's
        // clear; eased, so neither end of the fade shows as an edge.
        let alphas: [CGFloat] = [0, 0.1, 0.32, 0.62, 0.86, 1]
        let colors = alphas.map { CGColor(colorSpace: space, components: [0, 0, 0, $0])! } as CFArray
        let locations: [CGFloat] = [0, 0.2, 0.4, 0.6, 0.8, 1]
        guard let ramp = CGGradient(colorsSpace: space, colors: colors, locations: locations) else { return }
        context.setBlendMode(.destinationIn)
        // In from the left, where the title's details sit.
        context.drawLinearGradient(ramp, start: .zero, end: CGPoint(x: width * 0.45, y: 0),
                                   options: .drawsAfterEndLocation)
        // Out towards the bottom, under the rows (the context's origin is its bottom left).
        context.drawLinearGradient(ramp, start: .zero, end: CGPoint(x: 0, y: height * 0.45),
                                   options: .drawsAfterEndLocation)
    }
}
