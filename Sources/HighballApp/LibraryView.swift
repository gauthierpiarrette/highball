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
    /// The chips stay as they were left: they reset on every start, which a player reported as a
    /// bug (Discord, 2026-10-05, 0.10.8).
    @AppStorage("library.sourceFilter") private var sourceFilter: LibrarySource?
    /// Off by default since the Home row (highball#252): installed games lead the screen in their
    /// own row, so the owned library below them is what the grid is for. On, it keeps every store
    /// to its installed games alike; it used to let Epic's owned games through until touched, and
    /// that read as a bug (highball#257).
    @AppStorage("library.installedOnly") private var installedOnly = false
    @AppStorage("library.verifiedOnly") private var verifiedOnly = false
    #if DEBUG
    /// HB_DEBUG_GAME="<title>": the first library item whose title contains it opens a few seconds after
    /// launch, so a script can capture game pages without a click (highball#279's page was checked this
    /// way). Compiled out of releases.
    @State private var debugGame: LibraryItem?
    #endif

    private var filtered: [LibraryItem] {
        state.libraryItems.filter { item in
            if let sourceFilter, item.source != sourceFilter { return false }
            if installedOnly && !item.installedAnywhere { return false }
            if verifiedOnly {
                guard state.gameDB.entry(for: item)?.status == "verified-local" else { return false }
            }
            if !search.isEmpty && !item.title.localizedCaseInsensitiveContains(search)
                && !state.displayTitle(item).localizedCaseInsensitiveContains(search) { return false }
            return true
        }
    }

    /// The Home row: installed games, the most recently played first (highball#252, the first
    /// piece taken from PR #230). Only once the grid holds more than the row, with a handful of
    /// games and nothing owned besides them the row would repeat every tile.
    private var homeItems: [LibraryItem] {
        let installed = LibraryIndex.installedForHome(state.libraryItems)
        guard state.libraryItems.count > 6, state.libraryItems.count > installed.count else { return [] }
        return installed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                filterBar
                // Installed games first, large, with Play on the cover. The verdict stays under
                // every cover, the grid below keeps every game, and the row steps aside as soon as
                // a search or a filter is on.
                if !homeItems.isEmpty && search.isEmpty && sourceFilter == nil && !installedOnly && !verifiedOnly {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            HB.eyebrow(L("Installed games"))
                            Text("\(homeItems.count)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 16) {
                                ForEach(homeItems) { item in
                                    LibraryTile(item: item, entry: entry(for: item), width: 176, playOnCover: true)
                                }
                            }
                            // Room inside the clip for a hovered tile's scale, stroke and shadow,
                            // which the scroll view cut off at the top (2026-09-26). The negative
                            // padding outside keeps the row where it was.
                            .padding(.vertical, 14).padding(.horizontal, 10)
                        }
                        .padding(.vertical, -14).padding(.horizontal, -10)
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
        #if DEBUG
        .navigationDestination(item: $debugGame) { GameDetailView(passedItem: $0) }
        .task {
            guard let wanted = ProcessInfo.processInfo.environment["HB_DEBUG_GAME"] else { return }
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                if let item = state.libraryItems.first(where: { $0.title.localizedCaseInsensitiveContains(wanted) }) { debugGame = item; return }
            }
        }
        #endif
    }

    private func entry(for item: LibraryItem) -> GameDBEntry? {
        state.gameDB.entry(for: item)
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
    /// The Home row shows Play on the cover without a hover, as a visible control, where the
    /// grid keeps it for the hover so covers stay clean at a glance.
    var playOnCover = false
    @State private var hovering = false
    @State private var coverDropTargeted = false

    private var blocked: Bool { entry?.isBlocked == true }
    /// Anti-cheat blocks the Windows build only: a native Mac one plays.
    private var playable: Bool { (state.prefersMacBuild(item) || (item.installed && !blocked)) && !state.busy }

    var body: some View {
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    CoverArt(item: item)
                        .saturation(blocked && !item.installedOnMac ? 0.15 : (item.installedAnywhere ? 1 : 0.45))
                        .brightness(item.installedAnywhere ? 0 : -0.08)
                    // The hover Play of the grid. A Home row tile keeps its corner Play instead: the
                    // button jumping from the corner to the middle under the pointer read as odd
                    // (Discord, 2026-10-05).
                    if hovering && playable && !playOnCover {
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
                        // A program you added whose file is gone has nothing to download: say so
                        // instead (highball#269).
                        Group {
                            if item.source == .pin {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .help(L("This program's file isn't there. Plug in the drive it is on, or remove it from the environment's programs."))
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                            }
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                    }
                    // The visible Play of the Home row, bottom right, clear of the badge and of
                    // the Running pill. It stays there while the pointer is in.
                    if playOnCover && playable && !isRunning {
                        Button { state.play(item) } label: {
                            ZStack {
                                Circle().fill(HB.amber).frame(width: 34, height: 34)
                                    .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color(red: 0.13, green: 0.08, blue: 0.01))
                                    .offset(x: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(format: L("Play %@"), state.displayTitle(item)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(8)
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
                .scaleEffect(hovering ? 1.02 : 1)
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
        .animation(.spring(duration: 0.2), value: hovering)
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
        .help(Self.tooltip(entry?.notes) ?? item.title)
        // The rename field, on the tile being renamed only. A blank name is a reset.
        .alert(L("Rename"), isPresented: Binding(get: { state.renaming?.id == item.id },
                                                  set: { if !$0 { state.renaming = nil } })) {
            TextField(L("Name"), text: Binding(get: { state.renameText }, set: { state.renameText = $0 }))
            Button(L("Rename")) { state.rename(item, to: state.renameText) }
            Button(L("Cancel"), role: .cancel) { state.renaming = nil }
        } message: {
            Text(String(format: L("The store keeps calling it %@. Leave the field empty to go back to that name."), item.title))
        }
        .contextMenu {
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
            Button(L("Rename…")) { state.beginRename(item) }
            if NameStore.name(for: item.id, in: state.customNames) != nil {
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
        .accessibilityLabel("\(item.title), \(item.source.rawValue)\(item.installedOnMac ? ", " + L("Installed in Steam for Mac") : item.installed ? "" : ", " + L("Not installed"))")
    }

    private var verdict: (String, Color)? { verdictLabel(entry?.status) }
    private var isRunning: Bool { item.steamAppID.map { state.session(forAppID: $0) != nil } ?? false }
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
        // own dimensions never take part in layout and the crop is a plain clip. The previous
        // GeometryReader-and-frame form rendered nothing on a macOS 27 beta for any image whose
        // aspect was not exactly 2:3 (#64): a chosen cover, or Steam's wide fallback art.
        Color.clear
            .overlay {
                // A user-chosen cover always wins (coverVersion invalidates after changes).
                if let custom = state.coverStore.coverURL(for: item.id),
                   let image = NSImage(contentsOf: custom) {
                    Image(nsImage: image).resizable().scaledToFill().id(state.coverVersion)
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
                } else {
                    placeholder
                }
            }
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
