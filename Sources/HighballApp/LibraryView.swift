import SwiftUI
import HighballKit

/// SwiftUI re-exports DeveloperToolsSupport.LibraryItem; this pins the name to ours
/// for the whole app target.
typealias LibraryItem = HighballKit.LibraryItem

// Home emphasizes installed games. The sidebar exposes source and status collections.

struct LibraryView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let section: AppSection
    @FocusState private var searchFocused: Bool
    /// Matches the adaptive download grid's column width, including its maximum.
    private func homeDownloadWidth(in contentWidth: CGFloat) -> CGFloat {
        guard contentWidth > 0 else { return 120 }
        let columns = max(1, floor((contentWidth + 18) / (115 + 18)))
        return min(145, (contentWidth - (columns - 1) * 18) / columns)
    }
    private var search: String { section == .search ? state.librarySearch : "" }
    private var verifiedOnly: Bool { section != .home && state.verifiedLibrarySections.contains(section) }
    private var verifiedBinding: Binding<Bool> {
        Binding(get: { verifiedOnly }, set: { value in
            if value { state.verifiedLibrarySections.insert(section) }
            else { state.verifiedLibrarySections.remove(section) }
        })
    }

    private var items: [LibraryItem] {
        state.libraryItems.filter { item in
            switch section {
            case .installed: if !item.installedAnywhere { return false }
            case .downloads: if item.installedAnywhere { return false }
            case .steam: if item.source != .steam { return false }
            case .epic: if item.source != .epic { return false }
            case .programs: if item.source != .pin { return false }
            default: break
            }
            if verifiedOnly && state.gameDB.entry(for: item)?.status != "verified-local" { return false }
            if !search.isEmpty && !item.title.localizedCaseInsensitiveContains(search)
                && !state.displayTitle(item).localizedCaseInsensitiveContains(search) { return false }
            return true
        }
    }
    private var installed: [LibraryItem] {
        items.filter(\.installedAnywhere).sorted {
            if $0.lastPlayed != $1.lastPlayed { return ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            return state.displayTitle($0).localizedStandardCompare(state.displayTitle($1)) == .orderedAscending
        }
    }
    private var downloadable: [LibraryItem] { items.filter { !$0.installedAnywhere } }

    var body: some View {
        @Bindable var state = state
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(section.title).font(.system(size: 34, weight: .bold, design: .rounded))
                        Spacer()
                        if section == .home {
                            Button(L("Add games")) { state.select(.addGames) }.buttonStyle(HBActionStyle())
                        } else {
                            Toggle(L("Verified only"), isOn: verifiedBinding).toggleStyle(.checkbox).font(.caption)
                        }
                    }
                    if section == .search {
                        TextField(L("Search your games"), text: $state.librarySearch).textFieldStyle(.roundedBorder).controlSize(.large)
                            .focused($searchFocused)
                    }
                    if items.isEmpty { emptyState }
                    else if section == .home {
                        if !installed.isEmpty {
                            VStack(alignment: .leading, spacing: 15) {
                                sectionHeading(L("Installed games"), count: installed.count, destination: .installed)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(spacing: 18) {
                                        ForEach(installed) { item in FeaturedGame(item: item, width: homeDownloadWidth(in: geometry.size.width - 64) * 1.5) }
                                    }.padding(.vertical, 8).padding(.horizontal, 4)
                                }.padding(.vertical, -8).padding(.horizontal, -4)
                            }
                        } else {
                            ContentUnavailableView(L("Your next game starts here"), systemImage: "gamecontroller",
                                                   description: Text(L("Choose a game below to install, or connect a store.")))
                        }
                        if !downloadable.isEmpty {
                            VStack(alignment: .leading, spacing: 15) {
                                sectionHeading(L("Ready to download"), count: downloadable.count, destination: .downloads)
                                // A small overview keeps Home short. The full collection is one click away.
                                gameGrid(Array(downloadable.prefix(12)), minimum: 115, maximum: 145)
                            }
                        }
                    } else {
                        Text(items.count == 1 ? L("1 game") : String(format: L("%d games"), items.count)).font(.caption).foregroundStyle(.secondary)
                        gameGrid(items, minimum: section == .installed ? 170 : 125, maximum: section == .installed ? 220 : 165)
                    }
                }
                .padding(32).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(HB.motion(reduceMotion), value: verifiedOnly)
        .id(section)
        .onAppear { searchFocused = section == .search }
        .onChange(of: state.searchFocusRequest) { _, _ in searchFocused = section == .search }
    }

    private func sectionHeading(_ title: String, count: Int, destination: AppSection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            Spacer()
            Button(L("See all")) { state.select(destination) }.buttonStyle(.link).font(.caption)
        }
    }

    private func gameGrid(_ games: [LibraryItem], minimum: CGFloat, maximum: CGFloat) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum, maximum: maximum), spacing: 18)], spacing: 24) {
            ForEach(games) { item in LibraryTile(item: item, entry: state.gameDB.entry(for: item)) }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if state.libraryLoading {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(L("Loading your library…")).font(.callout).foregroundStyle(.secondary)
            }.padding(.vertical, 32)
        } else if !search.isEmpty || verifiedOnly {
            ContentUnavailableView(L("No matching games"), systemImage: "magnifyingglass", description: Text(L("Try another search or turn off the filter.")))
        } else if !state.damagedBottles.isEmpty && state.bottles.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("An environment needs attention. Your games may still be on disk.")).foregroundStyle(.secondary)
                Button(L("Open Troubleshooting")) { state.openSettings(.troubleshooting) }
            }.padding(.vertical, 32)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                Text(section == .downloads ? L("All your games are installed") : L("Build your library")).font(.title2.weight(.semibold))
                Text(L("Connect Steam or Epic, or add a Windows program from your Mac.")).foregroundStyle(.secondary)
                Button(L("Add games")) { state.select(.addGames) }.buttonStyle(HBActionStyle(primary: true))
            }.padding(.vertical, 32)
        }
    }
}

/// Large installed-game artwork, with one clear launch action and a separate details link.
private struct FeaturedGame: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: LibraryItem
    let width: CGFloat
    @State private var hovering = false
    @State private var coverDropTargeted = false
    private var playable: Bool {
        !state.busy && (state.prefersMacBuild(item) || (item.installed && state.gameDB.entry(for: item)?.isBlocked != true))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { state.navigate(.game(item)) } label: {
                ZStack(alignment: .bottomLeading) {
                    // Steam's portrait covers are 2:3. Fit custom and fallback art too.
                    CoverArt(item: item, contentMode: .fit).frame(width: width, height: width * 1.5)
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                    SourceBadge(source: item.source, mac: state.macSteamBuild(for: item)).padding(14)
                }.clipShape(RoundedRectangle(cornerRadius: 16))
                    .onDrop(of: [.image], isTargeted: $coverDropTargeted) { providers in
                        state.acceptCoverDrop(providers, for: item)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .stroke(coverDropTargeted ? HB.amber : .clear, lineWidth: 2))
            }.buttonStyle(.plain).accessibilityLabel(state.displayTitle(item))
            HStack(spacing: 10) {
                Button { state.navigate(.game(item)) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.displayTitle(item)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(L("Installed")).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                Button { state.play(item) } label: {
                    Image(systemName: "play.fill").font(.system(size: 12, weight: .semibold))
                        .frame(width: 34, height: 34).hbGlass(radius: 17, interactive: true)
                }.buttonStyle(.plain).disabled(!playable).accessibilityLabel(String(format: L("Play %@"), state.displayTitle(item)))
            }
        }.frame(width: width)
        .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
        .animation(HB.motion(reduceMotion), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu { GameContextActions(item: item, playable: playable) }
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
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(Capsule().fill(on ? HB.amber : .clear))
                .foregroundStyle(on ? Color(red: 0.13, green: 0.08, blue: 0.01) : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// The 2:3 portrait cover tile. Not GameCard: portrait geometry, title below the art,
/// click = detail, hover-play = launch.
struct LibraryTile: View {
    @Environment(AppState.self) private var state
    let item: LibraryItem
    let entry: GameDBEntry?
    var width: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var coverDropTargeted = false

    private var blocked: Bool { entry?.isBlocked == true }
    /// Anti-cheat blocks the Windows build only: a native Mac one plays.
    private var playable: Bool { (state.prefersMacBuild(item) || (item.installed && !blocked)) && !state.busy }

    var body: some View {
        Button { state.navigate(.game(item)) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    CoverArt(item: item)
                        .saturation(blocked && !item.installedOnMac ? 0.15 : (item.installedAnywhere ? 1 : 0.45))
                        .brightness(item.installedAnywhere ? 0 : -0.08)
                    if hovering && playable {
                        ZStack {
                            Color.black.opacity(0.25)
                            Button { hovering = false; state.play(item) } label: {
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
                    SourceBadge(source: item.source, mac: state.macSteamBuild(for: item))
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
                    if !item.installedAnywhere {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(6)
                    }
                }
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))   // hits stop where the cover is drawn, see CoverArt
                // An image dropped on the tile becomes the cover, so nobody has to walk a file
                // browser for it (highball#175). Only images are claimed here, so a dropped
                // Windows program still reaches the window's own handler and runs.
                .onDrop(of: [.image], isTargeted: $coverDropTargeted) { providers in
                    state.acceptCoverDrop(providers, for: item)
                }
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(coverDropTargeted ? HB.amber : (hovering ? HB.amber.opacity(0.55) : HB.cardStroke),
                            lineWidth: coverDropTargeted ? 2 : 1))
                .scaleEffect(hovering && !reduceMotion ? 1.025 : 1)
                .shadow(color: .black.opacity(hovering ? 0.4 : 0.2), radius: hovering ? 12 : 5, y: 3)

                Text(state.displayTitle(item))
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
        .animation(HB.motion(reduceMotion), value: hovering)
        // Continuous hover, not onHover: onHover only reports crossing the tile's edge, so a
        // game started from the play button took the screen with the pointer still inside, the
        // exit never came, and the play button stayed on that tile after coming back, while the
        // tile actually under the pointer stayed dark until it was left and re-entered
        // (highball#224). Leaving the app also clears it.
        .onContinuousHover { phase in
            switch phase {
            case .active: if !hovering { hovering = true }
            case .ended: hovering = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hovering = false
        }
        .help(Self.tooltip(entry?.notes) ?? state.displayTitle(item))
        .contextMenu { GameContextActions(item: item, playable: playable) }
        .accessibilityLabel("\(state.displayTitle(item)), \(item.source.rawValue)\(item.installedOnMac ? ", " + L("Installed in Steam for Mac") : item.installed ? "" : ", " + L("Not installed"))")
    }

    private var verdict: (String, Color)? { verdictLabel(entry?.status) }
}

/// The same game actions are available from Home and the full library.
private struct GameContextActions: View {
    @Environment(AppState.self) private var state
    let item: LibraryItem
    let playable: Bool

    @ViewBuilder var body: some View {
        if let appid = item.steamAppID, let running = state.session(forAppID: appid) {
            Button(L("Stop")) { state.stopSession(running) }
        } else if playable { Button(L("Play")) { state.play(item) } }
        if MacAppStub.existing(for: item.title) != nil {
            Button(L("Remove the Mac app")) { state.removeMacApp(title: item.title) }
        } else if playable, item.installed, PlayLink.target(for: item) != nil {
            Button(L("Make a Mac app…")) { state.makeMacApp(for: item) }
        }
        Button(L("Choose cover image…")) { state.chooseCover(for: item) }
        if state.coverStore.coverURL(for: item.id) != nil {
            Button(L("Reset cover")) { state.resetCover(for: item) }
        }
        Button(L("Rename…")) {
            state.beginRename(item)
            state.navigate(.game(item))
        }
        if state.customNames[item.id] != nil {
            Button(L("Reset name")) { state.resetName(for: item) }
        }
        // A program someone added by hand leaves the library from its tile, not only from
        // the environment's programs list (highball-db#68). Steam and Epic entries follow
        // their stores' libraries, so they have no such button.
        if item.source == .pin, let bottleName = item.bottleName,
           let bottle = state.bottles.first(where: { $0.name == bottleName }),
           let pin = bottle.settings.pins.first(where: { $0.id == item.pinID }) {
            Divider()
            Button(L("Remove from list"), role: .destructive) { state.removePin(pin, from: bottle) }
        }
        // Removing the game itself, not just the entry: asked for on r/macgaming because
        // there was nowhere to do it (highball#185).
        if item.installed {
            Divider()
            Button(L("Uninstall…"), role: .destructive) { state.askUninstall(item) }
        }
    }
}

/// Shared verdict mapping (was embedded in GameCard).
func verdictLabel(_ status: String?) -> (String, Color)? {
    switch status {
    case "verified-local": return (L("Verified"), HB.good)
    case "reported-upstream": return (L("Reported"), Color(red: 0.55, green: 0.70, blue: 0.90))
    case "community": return (L("Community"), HB.warn)
    case let s? where s.hasPrefix("blocked-"): return (L("Blocked"), HB.bad)
    default: return nil
    }
}

struct SourceBadge: View {
    let source: LibrarySource
    /// A native Mac build on Steam (MacSteamBuild): an Apple logo in front of the label, and the
    /// whole badge lit when Steam for Mac has it installed.
    var mac: MacSteamBuild? = nil
    private var label: String {
        switch source { case .steam: "STEAM"; case .epic: "EPIC"; case .pin: "EXE" }
    }
    private var lit: Bool { mac == .installed }
    var body: some View {
        HStack(spacing: 3) {
            if mac != nil { Image(systemName: "apple.logo").font(.system(size: 8, weight: .semibold)) }
            Text(label)
        }
            .font(.system(size: 8.5, weight: lit ? .bold : .medium).monospaced())
            .kerning(0.4)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(lit ? .white.opacity(0.92) : .black.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(lit ? 0 : 0.18), lineWidth: 0.5))
            .foregroundStyle(lit ? .black : .white.opacity(0.92))
            .help(lit ? L("Installed in Steam for Mac") : mac != nil ? L("Native Mac build on Steam") : "")
    }
}

/// Portrait cover with a fallback chain: tall art → wide art scaled to fill → placeholder.
/// AsyncImage can't chain URLs itself, so the state walks the chain on failure. Steam's
/// library_600x900 404s for some older appids — the fallback is not optional polish.
struct CoverArt: View {
    @Environment(AppState.self) private var state
    let item: LibraryItem
    var contentMode: ContentMode = .fill
    @State private var stage = 0

    private var url: URL? {
        switch stage {
        case 0: item.artworkTall ?? item.artworkWide
        case 1: item.artworkTall != nil ? item.artworkWide : nil
        default: nil
        }
    }

    var body: some View {
        // The tile takes the size its parent proposes; the image lives in an overlay, so its
        // own dimensions never take part in layout. The previous
        // GeometryReader-and-frame form rendered nothing on a macOS 27 beta for any image whose
        // aspect was not exactly 2:3 (#64): a chosen cover, or Steam's wide fallback art.
        Color.clear
            .overlay {
                // A user-chosen cover always wins (coverVersion invalidates after changes).
                if let custom = state.coverStore.coverURL(for: item.id),
                   let image = NSImage(contentsOf: custom) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode).id(state.coverVersion)
                } else if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: contentMode)
                        case .failure:
                            placeholder.onAppear { stage += 1 }
                        default:
                            Rectangle().fill(HB.card)
                        }
                    }
                } else {
                    placeholder
                }
            }
            .background(HB.card)
            .clipped()
            // clipped() trims the drawing, not hit testing: a wide cover scaled to fill (Steam's
            // fallback art, Half-Life 2's demo, Heartopia) still caught the pointer over the
            // neighbouring tiles, so the tile to the left showed the next one's play button and
            // its clicks went nowhere (seen on an M4, 2026-10-01). Hits stop at the visible cover.
            .contentShape(Rectangle())
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
