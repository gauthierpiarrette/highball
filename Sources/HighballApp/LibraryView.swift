import SwiftUI
import HighballKit

/// SwiftUI re-exports DeveloperToolsSupport.LibraryItem; this pins the name to ours
/// for the whole app target.
typealias LibraryItem = HighballKit.LibraryItem

// One Library (Phase 2): the app's primary surface. One uniform cover grid across all
// bottles and sources — store is a corner badge and a filter chip, never a section; the
// bottle is a per-game property on the detail page, never the navigation.

struct LibraryView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    @State private var search = ""
    @State private var sourceFilter: LibrarySource?
    @State private var installedOnly = false
    @State private var verifiedOnly = false

    private var filtered: [LibraryItem] {
        state.libraryItems.filter { item in
            if let sourceFilter, item.source != sourceFilter { return false }
            if installedOnly && !item.installed { return false }
            if verifiedOnly {
                guard let appid = item.steamAppID,
                      state.gameDB[appid]?.status == "verified-local" else { return false }
            }
            if !search.isEmpty && !item.title.localizedCaseInsensitiveContains(search) { return false }
            return true
        }
    }

    /// Only once the grid needs it: with a handful of games the row would repeat every tile.
    private var continueItems: [LibraryItem] {
        guard state.libraryItems.count > 6 else { return [] }
        return state.libraryItems
            .filter { $0.lastPlayed != nil && $0.installed }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(10).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                filterBar
                if !continueItems.isEmpty && search.isEmpty && sourceFilter == nil {
                    VStack(alignment: .leading, spacing: 12) {
                        HB.eyebrow(L("Continue playing"))
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(continueItems) { item in
                                    LibraryTile(item: item, entry: entry(for: item), width: 128)
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        HB.eyebrow(L("Library"))
                        Text("\(filtered.count)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                    if filtered.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 14)],
                                  spacing: 18) {
                            ForEach(filtered) { item in
                                LibraryTile(item: item, entry: entry(for: item))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BottleBackdrop())
        .searchable(text: $search, prompt: L("Search your games"))
        .navigationDestination(for: LibraryItem.self) { GameDetailView(passedItem: $0) }
    }

    private func entry(for item: LibraryItem) -> GameDBEntry? {
        item.steamAppID.flatMap { state.gameDB[$0] }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            FilterChip(label: L("All"), on: sourceFilter == nil) { sourceFilter = nil }
            FilterChip(label: "Steam", on: sourceFilter == .steam) { sourceFilter = .steam }
            FilterChip(label: "Epic", on: sourceFilter == .epic) { sourceFilter = .epic }
            FilterChip(label: L("Programs"), on: sourceFilter == .pin) { sourceFilter = .pin }
            Divider().frame(height: 16)
            FilterChip(label: L("Installed"), on: installedOnly) { installedOnly.toggle() }
            FilterChip(label: L("Verified"), on: verifiedOnly) { verifiedOnly.toggle() }
            Spacer()
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.bottles.isEmpty {
                if state.busy {
                    Text(L("Highball is preparing your Windows environment. Your games will appear here."))
                        .foregroundStyle(.secondary)
                } else if !state.damagedBottles.isEmpty {
                    // A present-but-unreadable environment must never look like a brand-new install:
                    // the games are likely still on disk, so point at recovery, not "prepare one".
                    Text(state.damagedBottles.count == 1
                         ? L("An environment needs attention — Highball can't read its settings, so its games aren't showing.")
                         : L("Some environments need attention — Highball can't read their settings, so their games aren't showing."))
                        .foregroundStyle(.secondary)
                    Button(L("Open Troubleshooting")) { state.settingsTab = .troubleshooting; openSettings() }
                        .buttonStyle(.borderedProminent).tint(HB.amber)
                } else {
                    // An engine without an environment: an older install, or a stopped first run.
                    Text(L("One more step: Highball prepares a Windows environment for your games."))
                        .foregroundStyle(.secondary)
                    Button(L("Prepare it now")) { state.makeDefaultEnvironment() }
                        .buttonStyle(.borderedProminent).tint(HB.amber)
                }
            } else if state.libraryItems.isEmpty {
                whereAreYourGames
            } else {
                Text(L("Nothing matches these filters.")).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 24)
    }

    /// Where your games are is a question anyone can answer (UX plan §3.2); Steam is not
    /// installed unasked, and a GOG or standalone user never waits for its first boot.
    private var whereAreYourGames: some View {
        VStack(alignment: .center, spacing: 22) {
            VStack(spacing: 6) {
                Text(L("Where are your games?")).font(.title.weight(.semibold))
                Text(L("Pick one to start. You can add the others any time.")).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                sourceCard(symbol: "gamecontroller.fill", accent: true, title: L("Steam"),
                           text: L("Install Steam and sign in. Your Steam library shows up here. Its first start takes 15 to 25 minutes."),
                           button: state.defaultBottle.map(state.steamInstalled) == true ? L("Open Steam") : L("Install Steam")) { state.installSteam() }
                sourceCard(symbol: "bag.fill", accent: false, title: L("Epic Games"),
                           text: L("Connect your Epic account. Your games install straight into Highball."),
                           button: L("Connect Epic")) { state.showEpicSignIn = true }
                sourceCard(symbol: "folder.fill", accent: false, title: L("A Windows program I have"),
                           text: L("An installer or game from your Mac. Or drop it onto this window."),
                           button: L("Choose a file…")) { state.chooseProgramToRun() }
            }
            Text(L("Battle.net, GOG Galaxy, the EA app, Ubisoft Connect and Rockstar are under Add games."))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func sourceCard(symbol: String, accent: Bool, title: String, text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.title3)
                .frame(width: 42, height: 42)
                .background(Circle().fill(accent ? HB.amber : Color.white.opacity(0.08)))
                .foregroundStyle(accent ? Color.black : Color.secondary)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if accent {
                Button(button, action: action).buttonStyle(.borderedProminent).tint(HB.amber).disabled(state.busy)
            } else {
                Button(button, action: action).buttonStyle(.bordered).disabled(state.busy)
            }
        }
        .padding(18)
        .frame(width: 250, height: 230, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(HB.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent ? HB.amber.opacity(0.5) : HB.cardStroke))
    }
}

struct FilterChip: View {
    let label: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Capsule().fill(on ? HB.amber : HB.card))
                .overlay(Capsule().stroke(on ? HB.amber : HB.cardStroke))
                .foregroundStyle(on ? Color(red: 0.13, green: 0.08, blue: 0.01) : .secondary)
        }
        .buttonStyle(.plain)
    }
}

/// The 2:3 portrait cover tile. Not GameCard: portrait geometry, title below the art,
/// click = detail, hover-play = launch.
struct LibraryTile: View {
    @Environment(AppState.self) private var state
    let item: LibraryItem
    let entry: GameDBEntry?
    var width: CGFloat? = nil
    @State private var hovering = false

    private var blocked: Bool { entry?.isBlocked == true }
    private var playable: Bool { item.installed && !blocked && !state.busy }

    var body: some View {
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    CoverArt(item: item)
                        .saturation(blocked ? 0.15 : (item.installed ? 1 : 0.45))
                        .brightness(item.installed ? 0 : -0.08)
                    if hovering && playable {
                        ZStack {
                            Color.black.opacity(0.25)
                            Button { state.play(item) } label: {
                                ZStack {
                                    Circle().fill(HB.amber).frame(width: 44, height: 44)
                                        .shadow(color: .black.opacity(0.45), radius: 9, y: 3)
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 17, weight: .bold))
                                        .foregroundStyle(Color(red: 0.13, green: 0.08, blue: 0.01))
                                        .offset(x: 1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .transition(.opacity)
                    }
                    SourceBadge(source: item.source)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(6)
                    if let appid = item.steamAppID, state.session(forAppID: appid) != nil {
                        Text(L("Running"))
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(HB.good.opacity(0.9), in: Capsule())
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(6)
                    }
                    if !item.installed {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(6)
                    }
                }
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(hovering ? HB.amber.opacity(0.55) : HB.cardStroke, lineWidth: 1))
                .scaleEffect(hovering ? 1.02 : 1)
                .shadow(color: .black.opacity(hovering ? 0.4 : 0.2), radius: hovering ? 12 : 5, y: 3)

                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                // Always reserve the verdict line: cells without one were shorter, and
                // LazyVGrid centers cells vertically, so those covers sank below the row.
                Text(verdict?.0 ?? " ")
                    .font(.system(size: 9, weight: .semibold).monospaced())
                    .foregroundStyle(verdict?.1 ?? .clear)
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
        .help(Self.tooltip(entry?.notes) ?? item.title)
        .contextMenu {
            if let appid = item.steamAppID, let running = state.session(forAppID: appid) {
                Button(L("Stop")) { state.stopSession(running) }
            } else if playable { Button(L("Play")) { state.play(item) } }
            if playable, PlayLink.target(for: item) != nil {
                Button(L("Make a Mac app…")) { state.makeMacApp(for: item) }
            }
            Button(L("Choose cover image…")) { state.chooseCover(for: item) }
            if state.coverStore.coverURL(for: item.id) != nil {
                Button(L("Reset cover")) { state.resetCover(for: item) }
            }
        }
        .accessibilityLabel("\(item.title), \(item.source.rawValue)\(item.installed ? "" : ", " + L("Not installed"))")
    }

    private var verdict: (String, Color)? { verdictLabel(entry?.status) }
}

/// Shared verdict mapping (was embedded in GameCard).
func verdictLabel(_ status: String?) -> (String, Color)? {
    switch status {
    case "verified-local": return (L("Verified"), HB.good)
    case "reported-upstream": return (L("Reported"), Color(red: 0.55, green: 0.70, blue: 0.90))
    case "community": return (L("Community"), HB.warn)
    case "blocked-anticheat": return (L("Blocked"), HB.bad)
    default: return nil
    }
}

struct SourceBadge: View {
    let source: LibrarySource
    private var label: String {
        switch source { case .steam: "STEAM"; case .epic: "EPIC"; case .pin: "EXE" }
    }
    var body: some View {
        Text(label)
            .font(.system(size: 8.5, weight: .medium).monospaced())
            .kerning(0.4)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.18), lineWidth: 0.5))
            .foregroundStyle(.white.opacity(0.92))
    }
}

/// Portrait cover with a fallback chain: tall art → wide art scaled to fill → placeholder.
/// AsyncImage can't chain URLs itself, so the state walks the chain on failure. Steam's
/// library_600x900 404s for some older appids — the fallback is not optional polish.
struct CoverArt: View {
    @Environment(AppState.self) private var state
    let item: LibraryItem
    @State private var stage = 0

    private var url: URL? {
        switch stage {
        case 0: item.artworkTall ?? item.artworkWide
        case 1: item.artworkTall != nil ? item.artworkWide : nil
        default: nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            // A user-chosen cover always wins (coverVersion invalidates after changes).
            if let custom = state.coverStore.coverURL(for: item.id),
               let image = NSImage(contentsOf: custom) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .id(state.coverVersion)
            } else if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder.onAppear { stage += 1 }
                    default:
                        Rectangle().fill(HB.card)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            } else {
                placeholder.frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [HB.card, HB.ground], startPoint: .top, endPoint: .bottom)
            Text(String(item.title.prefix(1)))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.quaternary)
        }
    }
}

extension LibraryTile {
    /// A tooltip is a glance, not the whole entry: the first sentence of the notes, capped.
    static func tooltip(_ notes: String?) -> String? {
        guard let notes, !notes.isEmpty else { return nil }
        let first = notes.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? notes
        let sentence = first.trimmingCharacters(in: .whitespaces) + "."
        return sentence.count <= 160 ? sentence : String(sentence.prefix(157)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
