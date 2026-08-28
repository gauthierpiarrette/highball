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

    private var continueItems: [LibraryItem] {
        state.libraryItems
            .filter { $0.lastPlayed != nil && $0.installed }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(10).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if state.busy && !state.stage.isEmpty && !state.showLog {
                    Label(state.stage, systemImage: "clock")
                        .font(.callout).foregroundStyle(.secondary)
                }
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
        .navigationDestination(for: LibraryItem.self) { GameDetailView(item: $0) }
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
                Text(L("No bottles yet. A bottle is a private Windows environment for your games."))
                    .foregroundStyle(.secondary)
                Button(L("Create your first bottle")) { state.requestCreateBottle = true }
                    .buttonStyle(.borderedProminent)
            } else if state.libraryItems.isEmpty {
                Text(L("No games yet. Install Steam in a bottle, or connect your Epic account."))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if let bottle = state.bottles.first(where: { $0.name == state.selectedBottle }) ?? state.bottles.first {
                        Button(L("Install Steam")) { state.applyRecipe("steam", to: bottle) }
                    }
                    Button(L("Connect Epic account…")) { state.showEpicSignIn = true }
                }
            } else {
                Text(L("Nothing matches these filters.")).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 24)
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
        .help(entry?.notes ?? item.title)
        .contextMenu {
            if playable { Button(L("Play")) { state.play(item) } }
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
