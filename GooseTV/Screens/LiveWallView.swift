import SwiftUI

#if os(tvOS)
/// Several channels at once on the Apple TV: two side by side, or four in a
/// square (see `LiveWall`). Left, right, up and down light another; its sound
/// is the one heard. Select on a channel offers it full screen, another
/// channel in its place, or taking it down; on the empty place, a channel to
/// add. Play goes full screen on the lit one, and so does Back.
///
/// The picture keeps focus throughout, as the full screen does: the lists are
/// highlights the presses move.
struct LiveWallView: View {
    @ObservedObject var wall: LiveWall
    /// The channels to choose from, favourites first.
    let channels: [LiveChannel]
    /// What's on a channel now, from the guide.
    let showing: (LiveChannel) -> LiveProgram?
    /// Where a channel's logo is, if the server has one.
    let logo: (LiveChannel) -> URL?
    /// Full screen on this channel: the wall comes down.
    let leave: (LiveChannel?) -> Void

    /// A list over the wall, for the place it was opened from.
    private enum Panel: Equatable {
        case none
        /// Full Screen, Change Channel, Remove.
        case actions(place: Int)
        /// The channels, to put one in the place.
        case channels(place: Int)
    }

    @State private var panel: Panel = .none
    @State private var line = 0
    /// The names under the pictures, up for a few seconds after a move.
    @State private var named = true
    @State private var naming: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Edge to edge, past the margins the rest of the app keeps:
            // the pictures are all there is on this screen.
            grid
                .ignoresSafeArea()
            RemoteSurface(actions: RemoteSurface.Actions(
                select: select,
                playPause: { leave(litChannel) },
                menu: back,
                up: { move(rows: -1) },
                down: { move(rows: 1) },
                tap: { direction in
                    guard panel == .none else { return }
                    move(by: direction > 0 ? 1 : -1)
                }))
                .tvExitCommand { back() }
                .accessibilityLabel(Text(Self.title))
                .ignoresSafeArea()
            switch panel {
            case .none:
                EmptyView()
            case .actions:
                column(title: litChannel?.name ?? Self.title, accent: Theme.palette[0],
                       rows: actions.map { ($0.title, nil, false) })
                    .transition(.opacity)
            case .channels(let place):
                channelColumn(title: wall.tiles.indices.contains(place) ? Self.changeTitle : Self.addTitle)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: panel)
        .onAppear { name() }
        .onDisappear { naming?.cancel() }
    }

    static var title: String {
        String(localized: "Multiview", comment: "Live TV: several channels on the screen at once, the sound from the one that's highlighted")
    }

    private var litChannel: LiveChannel? {
        wall.tiles.indices.contains(wall.lit) ? wall.tiles[wall.lit].channel : wall.tiles.first?.channel
    }

    // MARK: The pictures

    private var grid: some View {
        let places = wall.places
        let columns = 2
        let rows = places / columns
        return GeometryReader { geo in
            // Touching: four 16:9 pictures fill the screen exactly. Two
            // side by side are as wide as they can be without cutting the
            // picture, which leaves the screen's height to spare above
            // and below.
            let gap: CGFloat = 0
            // As big as 16:9 pictures can be, two to a row.
            let width = min((geo.size.width - gap) / 2, (geo.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows) * 16 / 9)
            let height = width * 9 / 16
            VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<columns, id: \.self) { column in
                            place(row * columns + column)
                                .frame(width: width, height: height)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func place(_ index: Int) -> some View {
        let lit = index == wall.lit
        let shape = Rectangle()
        Group {
            if wall.tiles.indices.contains(index) {
                TileView(tile: wall.tiles[index], lit: lit, named: named || lit, showing: showing)
            } else if index == wall.tiles.count {
                // Room for one more.
                VStack(spacing: 14) {
                    Image(systemName: "plus")
                        .font(.app(44, .semibold))
                    Text(Self.addTitle)
                        .font(.app(22, .semibold))
                }
                .foregroundStyle(.white.opacity(lit ? 1 : 0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white.opacity(lit ? 0.12 : 0.05), in: shape)
            } else {
                Color.white.opacity(0.03)
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white, lineWidth: lit ? 5 : 0) }
        .animation(.easeOut(duration: 0.12), value: lit)
    }

    private static var changeTitle: String {
        String(localized: "Change Channel", comment: "Multiview: puts another channel in the highlighted place")
    }

    private static var addTitle: String {
        String(localized: "Add a Channel", comment: "Multiview: the empty place, where another channel can be put")
    }

    // MARK: Presses

    private func move(by step: Int) {
        let places = wall.places
        let column = wall.lit % 2
        let next = column + step
        guard next >= 0, next < 2 else { return }
        land(wall.lit + step, places: places)
    }

    private func move(rows step: Int) {
        if panel != .none {
            line = min(max(line + step, 0), panelCount - 1)
            return
        }
        land(wall.lit + step * 2, places: wall.places)
    }

    /// Onto a place that's a channel or the empty one, and no further.
    private func land(_ place: Int, places: Int) {
        guard place >= 0, place < places, place <= wall.tiles.count, place < LiveWall.most else { return }
        wall.light(place)
        name()
    }

    private func select() {
        switch panel {
        case .none:
            if wall.tiles.indices.contains(wall.lit) {
                line = 0
                panel = .actions(place: wall.lit)
            } else {
                openChannels(for: wall.lit)
            }
        case .actions(let place):
            let chosen = actions.indices.contains(line) ? actions[line] : nil
            panel = .none
            chosen?.run(place)
        case .channels(let place):
            panel = .none
            guard channels.indices.contains(line) else { return }
            wall.put(channels[line], at: place)
            name()
        }
    }

    private func back() {
        if panel != .none { return panel = .none }
        leave(litChannel)
    }

    private func openChannels(for place: Int) {
        // On the channel that's there, or the first not on the wall.
        let current = wall.tiles.indices.contains(place) ? wall.tiles[place].channel.id : nil
        line = channels.firstIndex { $0.id == current }
            ?? channels.firstIndex { channel in !wall.tiles.contains { $0.channel.id == channel.id } } ?? 0
        panel = .channels(place: place)
    }

    private struct Action {
        let title: String
        let run: (Int) -> Void
    }

    private var actions: [Action] {
        var list = [
            Action(title: String(localized: "Full Screen", comment: "Multiview: shows the highlighted channel on the whole screen, leaving the others")) { place in
                leave(wall.tiles.indices.contains(place) ? wall.tiles[place].channel : nil)
            },
            Action(title: Self.changeTitle) { place in
                openChannels(for: place)
            },
        ]
        // Another beside these, where two fill the screen side by side.
        if wall.tiles.count < LiveWall.most, wall.tiles.count == wall.places {
            list.append(Action(title: Self.addTitle) { _ in openChannels(for: wall.tiles.count) })
        }
        // The last channel stays: a wall of none is the full screen.
        if wall.tiles.count > 1 {
            list.append(Action(title: String(localized: "Remove", comment: "Multiview: takes the highlighted channel off the screen, letting its tuner go")) { place in
                wall.remove(at: place)
                name()
            })
        }
        return list
    }

    private var panelCount: Int {
        switch panel {
        case .none: 0
        case .actions: actions.count
        case .channels: channels.count
        }
    }

    /// The names up for a while, as they come up after a move.
    private func name() {
        named = true
        naming?.cancel()
        naming = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { named = false }
        }
    }

    // MARK: The lists

    /// The channels to choose from, each with its logo, a window of the
    /// list at a time around the line the presses have reached. A tick on
    /// the ones already up.
    private func channelColumn(title: String) -> some View {
        let visible = 7
        let first = min(max(line - visible / 2, 0), max(channels.count - visible, 0))
        let shown = Array(channels.enumerated()).dropFirst(first).prefix(visible)
        return PlayerPanelColumn(title: title, accent: Theme.palette[2]) {
            ForEach(Array(shown), id: \.offset) { index, channel in
                let lit = index == line
                HStack(spacing: 14) {
                    Image(systemName: "checkmark")
                        .font(.app(16, .bold))
                        .opacity(wall.tiles.contains { $0.channel.id == channel.id } ? 1 : 0)
                        .frame(width: CGFloat(22).scaled)
                    // On a plate of its own: a white logo on the lit
                    // line's white would be lost.
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(white: 0.12))
                        if let url = logo(channel) {
                            RemoteImage(url: url, contentMode: .fit)
                                .padding(5)
                        } else {
                            Text(channel.number ?? String(channel.name.prefix(3)))
                                .font(.app(15, .heavy))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .padding(.horizontal, 4)
                        }
                    }
                    .frame(width: CGFloat(78).scaled, height: CGFloat(46).scaled)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(channel.name)
                            .font(.app(20, lit ? .bold : .medium))
                            .lineLimit(1)
                        let detail = [channel.number, showing(channel)?.name].compactMap { $0 }.joined(separator: " · ")
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.app(15, .medium))
                                .opacity(0.6)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(lit ? Color.black : Color.white)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(lit ? Color.white : Color.clear)
                }
            }
        }
        .frame(width: CGFloat(640).scaled, alignment: .leading)
        .padding(.trailing, 80)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    /// A list at the foot of the screen on the right, the line the presses
    /// have reached lit, a window of it at a time.
    private func column(title: String, accent: (Color, Color), rows: [(String, String?, Bool)]) -> some View {
        let visible = 8
        let first = min(max(line - visible / 2, 0), max(rows.count - visible, 0))
        let shown = Array(rows.enumerated()).dropFirst(first).prefix(visible)
        return PlayerPanelColumn(title: title, accent: accent) {
            ForEach(Array(shown), id: \.offset) { index, row in
                PlayerPanelRow(title: row.0, detail: row.1, chosen: row.2)
                    .foregroundStyle(index == line ? Color.black : Color.white)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(index == line ? Color.white : Color.clear)
                    }
            }
        }
        .frame(maxWidth: CGFloat(760).scaled, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 80)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

/// One channel on the wall: its picture, or what's wrong in its place; its
/// name and what's on, while names are up; a speaker on the one heard.
private struct TileView: View {
    @ObservedObject var tile: LiveWall.Tile
    let lit: Bool
    let named: Bool
    let showing: (LiveChannel) -> LiveProgram?

    var body: some View {
        ZStack {
            LiveWallSurface(tile: tile)
                .opacity(tile.phase == .playing ? 1 : 0)
            switch tile.phase {
            case .playing:
                EmptyView()
            case .tuning:
                ProgressView()
            case .refused, .lost, .unplayable:
                Text(trouble ?? "")
                    .font(.app(19, .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            if named {
                VStack(alignment: .leading, spacing: 3) {
                    Text([tile.channel.number, tile.channel.name].compactMap { $0 }.joined(separator: " "))
                        .font(.app(19, .bold))
                    if let program = showing(tile.channel) {
                        Text(program.name)
                            .font(.app(16, .medium))
                            .opacity(0.75)
                    }
                }
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if lit, tile.phase == .playing {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.app(18, .bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.6), in: Circle())
                    .padding(12)
            }
        }
        .animation(.easeOut(duration: 0.2), value: named)
    }

    private var trouble: String? {
        switch tile.phase {
        case .refused: LiveTuner.Phase.refused.trouble
        case .lost: LiveTuner.Phase.lost.trouble
        case .unplayable: LiveTuner.Phase.unplayable.trouble
        default: nil
        }
    }
}
#endif
