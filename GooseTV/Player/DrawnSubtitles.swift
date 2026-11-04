#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// One line or block of subtitle, in the film's own seconds.
struct WebVTTCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// Reads the cues out of a WebVTT file, which is how Jellyfin serves any text
/// subtitle when asked for `Stream.vtt`. Styling tags are dropped: the lines
/// are drawn in one plain style.
enum WebVTT {
    static func cues(in file: String) -> [WebVTTCue] {
        let blocks = file.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        return blocks.compactMap { block -> WebVTTCue? in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let ends = lines[timing].components(separatedBy: "-->")
            guard ends.count == 2,
                  let start = seconds(ends[0]),
                  // Cue settings (position, alignment) follow the end time.
                  let end = seconds(ends[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "")
            else { return nil }
            let text = lines[(timing + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&nbsp;", with: " ")
            guard !text.isEmpty else { return nil }
            return WebVTTCue(start: start, end: end, text: text)
        }
        .sorted { $0.start < $1.start }
    }

    /// "01:02:03.456" or "02:03.456".
    private static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard (2...3).contains(parts.count), let last = Double(parts.last!.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return parts.dropLast().reduce(0) { total, part in total * 60 + (Double(part) ?? 0) } * 60 + last
    }
}

/// A subtitle the app draws over the picture itself, following the film's
/// clock rather than the stream's.
///
/// Used where the stream's own subtitles would be wrong: Jellyfin's run ten
/// seconds late over the fragmented MP4 that HEVC has to travel in. Used
/// from the main thread, like the player it sits over.
final class DrawnSubtitles {
    private let label = UILabel()
    /// Behind the lines, when Settings asks for a background: one plate for
    /// the block, a little wider than its longest line.
    private let plate = UIView()
    /// How far the plate reaches past the words on a television; in
    /// proportion on a smaller screen, as the words are.
    private static let plateInset = CGSize(width: 18, height: 8)
    private var plateEdges: [NSLayoutConstraint] = []
    private var inset: CGSize {
        CGSize(width: Self.plateInset.width * sizeScale, height: Self.plateInset.height * sizeScale)
    }
    /// Says the subtitle is on its way, or that it didn't come. The first time
    /// a server is asked for one inside a big file it reads the whole file to
    /// pull it out, which on a 4K remux takes twenty seconds or more; without
    /// this, choosing a subtitle looked like it had done nothing.
    private let status = UILabel()
    private var loaded = false
    private var task: URLSessionDataTask?
    private var url: URL?
    private let started = Date()
    private var cues: [WebVTTCue] = []
    private var showing: [WebVTTCue] = []
    /// Seconds to show every line later than its file says; negative for
    /// earlier. For a subtitle timed to a different cut of the film.
    var delay: Double = 0
    /// Where the lines sit above the bottom of the picture.
    private var bottom: NSLayoutConstraint?
    private var statusBottom: NSLayoutConstraint?
    private var raised = false

    /// How far up the lines' foot is: where Settings puts them, or clear of
    /// the player's controls while those are up.
    private var rise: CGFloat {
        let bounds = plate.superview?.bounds.size ?? .zero
        return SubtitleAppearance.place.rise(onScreen: min(bounds.width, bounds.height), controlsUp: raised)
    }

    /// Raises the lines clear of the player's controls while they're up, and
    /// lets them back down after.
    func makeRoom(_ raised: Bool) {
        self.raised = raised
        settle(animated: true)
    }

    /// The plate reaches a little below the lines, so it is set that much
    /// lower and the lines stay where they would be without it.
    private func settle(animated: Bool) {
        let inset = inset
        if plateEdges.count == 4, plateEdges[0].constant != inset.width {
            plateEdges[0].constant = inset.width
            plateEdges[1].constant = -inset.width
            plateEdges[2].constant = inset.height
            plateEdges[3].constant = -inset.height
            plate.drawnLayer.cornerRadius = 8 * sizeScale
        }
        let constant = -rise + inset.height
        guard let bottom, bottom.constant != constant, let view = plate.superview else { return }
        bottom.constant = constant
        statusBottom?.constant = -rise
        if animated { UIView.animate(withDuration: 0.25) { view.layoutIfNeeded() } }
    }

    /// Puts the label over the picture and fetches the cues. Until they
    /// arrive, nothing is drawn.
    init(url: URL, over view: UIView) {
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isUserInteractionEnabled = false
        // The softer of the two shadows, under the tight one the text carries
        // (see `styled`), for lines over a bright picture.
        label.drawnLayer.shadowColor = UIColor.black.cgColor
        label.drawnLayer.shadowOpacity = 0.9
        label.drawnLayer.shadowRadius = 4
        label.drawnLayer.shadowOffset = .zero
        plate.translatesAutoresizingMaskIntoConstraints = false
        plate.isUserInteractionEnabled = false
        plate.drawnLayer.cornerRadius = 8
        plate.isHidden = true
        plate.addSubview(label)
        view.addSubview(plate)
        plateEdges = [
            label.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: Self.plateInset.width),
            label.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -Self.plateInset.width),
            label.topAnchor.constraint(equalTo: plate.topAnchor, constant: Self.plateInset.height),
            label.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -Self.plateInset.height),
        ]
        NSLayoutConstraint.activate(plateEdges + [
            plate.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            plate.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
        ])
        let resting = SubtitleAppearance.place.rise(onScreen: min(view.bounds.width, view.bounds.height))
        let bottom = plate.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -resting + Self.plateInset.height)
        bottom.isActive = true
        self.bottom = bottom

        status.translatesAutoresizingMaskIntoConstraints = false
        status.isUserInteractionEnabled = false
        status.font = .systemFont(ofSize: 24, weight: .medium)
        status.textColor = UIColor.white.withAlphaComponent(0.85)
        status.drawnLayer.shadowColor = UIColor.black.cgColor
        status.drawnLayer.shadowOpacity = 0.9
        status.drawnLayer.shadowRadius = 3
        status.drawnLayer.shadowOffset = .zero
        status.alpha = 0
        status.numberOfLines = 2
        status.textAlignment = .center
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.6),
        ])
        let statusBottom = status.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -resting)
        statusBottom.isActive = true
        self.statusBottom = statusBottom

        self.url = url
        fetch()
        // Only when it's slow: a subtitle the server already has arrives at
        // once, and a note that flashes up and away is worse than none.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.loaded else { return }
            self.setStatus(String(localized: "Loading subtitles…"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.loaded else { return }
            self.setStatus(String(localized: "Loading subtitles… The first time, a large film can take a few minutes.",
                                  comment: "Shown while the server extracts a subtitle from a big video file for the first time"))
        }
    }

    /// Asks for the cues, and asks again when a request times out: the server
    /// keeps extracting after the request gives up (a 55 GB remux took several
    /// minutes the first time, and was instant after), so a timeout means "not
    /// yet", not "no". Anything else, or a quarter of an hour, is a failure.
    private func fetch() {
        guard let url, !loaded else { return }
        let request = URLRequest(url: url, timeoutInterval: 60)
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            // A file kept beside a download has no HTTP status: read is read.
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? (url.isFileURL && data != nil)
            let file = ok ? data.flatMap { String(data: $0, encoding: .utf8) } : nil
            let cues = file.map(WebVTT.cues(in:))
            let timedOut = (error as? URLError)?.code == .timedOut
            DispatchQueue.main.async {
                guard let self, !self.loaded else { return }
                if let cues {
                    self.loaded = true
                    self.cues = cues
                    self.setStatus(nil)
                } else if timedOut, Date().timeIntervalSince(self.started) < 15 * 60 {
                    self.fetch()
                } else {
                    self.loaded = true
                    self.setStatus(String(localized: "Couldn't load subtitles"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.setStatus(nil) }
                }
            }
        }
        task?.resume()
    }

    private func setStatus(_ text: String?) {
        if let text { status.text = text }
        UIView.animate(withDuration: 0.25) { self.status.alpha = text == nil ? 0 : 1 }
    }

    /// Shows whatever is due at this point in the film.
    func show(atFilmSeconds seconds: Double) {
        let due = dueCues(at: seconds - delay)
        guard due != showing else { return }
        showing = due
        label.attributedText = due.isEmpty ? nil : Self.styled(due.map(\.text).joined(separator: "\n"), scale: sizeScale)
        // As Settings has them now: a change there shows from the next line.
        plate.isHidden = due.isEmpty
        plate.backgroundColor = UIColor.black.withAlphaComponent(SubtitleAppearance.backing.opacity)
        settle(animated: false)
    }

    func remove() {
        task?.cancel()
        loaded = true
        status.removeFromSuperview()
        plate.removeFromSuperview()
    }

    /// Cues are sorted by start, so the search stops at the first one not yet
    /// begun; lines that overlap are all shown.
    private func dueCues(at seconds: Double) -> [WebVTTCue] {
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= seconds { low = mid + 1 } else { high = mid }
        }
        // Anything still showing started within the last few cues.
        return cues[max(0, low - 8)..<low].filter { $0.end > seconds }
    }

    /// In the colour chosen in Settings (white, unless changed) with a dark
    /// edge, readable over bright and dark pictures alike, at the size chosen
    /// there. The edge is a tight shadow,
    /// not a stroke: a stroke is drawn across the letter's outline, so half of
    /// it lands inside and greys the white, and a wide one spikes at corners.
    /// The sizes are a 1080-point-tall television's; any other screen gets
    /// them in proportion to its shorter side, which on the Apple TV is 1080.
    private var sizeScale: CGFloat {
        guard let view = plate.superview, view.bounds.width > 0, view.bounds.height > 0 else { return 1 }
        return min(view.bounds.width, view.bounds.height) / 1080
    }

    private static func styled(_ text: String, scale: CGFloat) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 4
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: SubtitleAppearance.size.points * scale, weight: .semibold),
            .foregroundColor: SubtitleAppearance.tint.uiColor,
            .shadow: shadow,
            .paragraphStyle: paragraph,
        ])
    }
}

extension UIView {
    /// The view's layer, on both platforms: a Mac view has one once asked to.
    fileprivate var drawnLayer: CALayer {
        #if os(macOS)
        wantsLayer = true
        return layer!
        #else
        return layer
        #endif
    }
}

extension SubtitleAppearance.Tint {
    var uiColor: UIColor {
        let (red, green, blue) = rgb
        return UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}
