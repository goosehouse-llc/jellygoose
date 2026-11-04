import SwiftUI

/// Everything in the library from one studio or network, reached from the
/// pills on a detail page.
struct StudioView: View {
    let studio: Studio
    @Environment(\.sectionNavigator) private var navigator

    var body: some View {
        ItemListGridView(title: studio.name,
                         eyebrow: String(localized: "Studio and network", comment: "Eyebrow above a studio's or TV network's name"),
                         accent: Theme.palette[2],
                         showDetails: { navigator.showItem($0.id) }) {
            try await $0.items(fromStudio: studio.id)
        }
    }
}

/// Everything in the library a cast or crew member worked on, reached by
/// clicking their face on a detail page.
struct PersonView: View {
    @Environment(\.appState) private var app
    let person: Person

    @State private var items: [BaseItem] = []
    @State private var loaded = false
    /// The person as the server describes them: biography, birth and birthplace.
    @State private var details: BaseItem?

    private let columns = [GridItem(.adaptive(minimum: Theme.posterWidth), spacing: 24)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 24) {
                    PersonPhoto(person: person, maxWidth: 400, glyphSize: 50)
                        .frame(width: CGFloat(200).scaled, height: CGFloat(200).scaled)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 6) {
                        Text(subtitle.uppercased())
                            .font(.app(13, .heavy))
                            .kerning(1.6)
                            .foregroundStyle(Theme.palette[3].1)
                        Text(person.name ?? String(localized: "Unknown", comment: "Shown when a person has no name"))
                            .font(.app(34, .bold))
                            .lineLimit(2)
                        if let facts {
                            Text(facts)
                                .font(.app(18))
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(2)
                        }
                        Text(countLabel)
                            .font(.app(18))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.bottom, 8)

                if let bio = biography {
                    // The first paragraph, a few lines of it; click for the rest.
                    ExpandableText(text: bio.first, full: bio.full, lines: 4, maxWidth: CGFloat(1300).scaled)
                        .padding(.bottom, 8)
                }

                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                        .focusable()
                } else if items.isEmpty {
                    Text("Nothing else in your library.")
                        .font(.app(18))
                        .foregroundStyle(Theme.textSecondary)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 32) {
                    ForEach(items) { item in
                        PosterNavCard(item: item)
                    }
                }
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, 48)
        }
        .pageSides()
        // Once: coming back from a film's page appears here again, and asked
        // again each time, it fetched the lot and swapped the grid under focus.
        .task { if !loaded { await load() } }
    }

    private var subtitle: String {
        if person.type == "Actor", let role = person.role, !role.isEmpty { return role }
        // Found by name in Search, there's no telling which they were.
        return person.type.map(ServerWords.personType) ?? String(localized: "Cast and Crew")
    }

    private var countLabel: String {
        guard loaded else { return String(localized: "Looking through your library…") }
        return String(localized: "\(items.count) titles in your library")
    }

    /// The biography, and its first paragraph for the short form.
    private var biography: (first: String, full: String)? {
        guard let full = details?.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !full.isEmpty else { return nil }
        let first = full.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? full
        return (first.trimmingCharacters(in: .whitespaces), full)
    }

    /// "Born 2 September 1964 (age 62) · Beirut, Lebanon", or with the date
    /// they died.
    private var facts: String? {
        guard let details else { return nil }
        var parts: [String] = []
        let born = Date(serverDay: details.premiereDate)
        let died = Date(serverDay: details.endDate)
        if let born {
            let style = Date.FormatStyle(date: .long, time: .omitted).locale(.current)
            let bornText = style.format(born)
            if let died {
                let age = Self.years(from: born, to: died)
                parts.append(String(localized: "\(bornText) – \(style.format(died)) (aged \(age))",
                                    comment: "A person's birth and death dates, and their age at death"))
            } else {
                let age = Self.years(from: born, to: Date())
                parts.append(String(localized: "Born \(bornText) (age \(age))", comment: "A person's birth date and age"))
            }
        }
        if let place = details.productionLocations?.first, !place.isEmpty { parts.append(place) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func years(from start: Date, to end: Date) -> Int {
        Calendar.current.dateComponents([.year], from: start, to: end).year ?? 0
    }

    private func load() async {
        guard let client = app?.client else { return }
        let id = person.id
        async let fetchedItems = (try? await client.items(withPerson: id)) ?? []
        async let fetchedDetails = try? await client.item(id: id)
        // One of each film: a 1080p and a 4K copy are two items to the server.
        var seen = Set<String>()
        items = await fetchedItems.filter { seen.insert($0.titleAndYear).inserted }
        details = await fetchedDetails
        loaded = true
    }
}
