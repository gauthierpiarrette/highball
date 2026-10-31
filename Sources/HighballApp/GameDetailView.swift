import SwiftUI
import HighballKit

/// Media and store copy alongside the existing launch plan; game settings stay inline below.
struct GameDetailView: View {
    @Environment(AppState.self) private var state
    let passedItem: LibraryItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var storeDetails: SteamGameDetails?
    @State private var sizes: AppState.InstalledSizes?
    @State private var windowsEstimate: DownloadEstimate?
    @State private var macEstimate: DownloadEstimate?
    /// The estimates have been asked for and answered (or not): "Checking…" until then, "Unknown" after.
    @State private var estimatesDone = false
    /// How this GOG game's saves sync, per version; asked when the page opens.
    @State private var cloudSetup: GOGSaves.CloudSetup?
    @State private var cloudSetupAsked = false
    @State private var showCloudHelp = false
    @State private var loadingDetails = true
    @State private var expandedDescription = false
    @State private var selectedGalleryURL: URL?
    @State private var choseGalleryImage = false
    /// The launch arguments being typed; saved on Return, on Play and when the page closes, so a
    /// space typed between two arguments is not normalised away mid-word.
    @State private var argsText = ""
    @State private var argsLoaded = false
    /// Saves a line still being typed, so the Play that follows launches with it. Skipped until the
    /// field has loaded, or its empty text would clear the stored arguments.
    private func commitTypedArguments() {
        guard argsLoaded else { return }
        state.setLaunchArguments(argsText, for: item)
    }
    /// The live row: after an install, a delete or a rename, the passed-in copy goes stale.
    private var item: LibraryItem { state.libraryItems.first { $0.id == passedItem.id } ?? passedItem }
    @State private var showWhy = false
    @State private var showAdvanced = false

    private var entry: GameDBEntry? { state.gameDB.entry(for: item) }
    private var bottle: Bottle? { item.bottleName.flatMap { name in state.bottles.first { $0.name == name } } }
    private var blocked: Bool { entry?.isBlocked == true }
    /// Steam already has an appmanifest for it (downloading or updating), as opposed to a game
    /// that is only owned.
    private var steamHasManifest: Bool {
        guard let name = item.bottleName, let appid = item.steamAppID else { return false }
        return state.gamesByBottle[name]?.contains { $0.appid == appid } == true
    }
    private var fixRecipe: HighballKit.Recipe? { state.fixRecipe(for: item) }
    private var fixApplied: Bool {
        guard let fixRecipe, let bottle else { return false }
        return bottle.settings.recipes.contains(fixRecipe.id) && fixRecipe.artifactsPresent(driveC: bottle.driveC, steamGames: state.gamesByBottle[bottle.name] ?? [])
    }
    private var running: GameSession? {
        if let appid = item.steamAppID, let s = state.session(forAppID: appid) { return s }
        return state.runningSessions.first { $0.title == item.title && $0.bottleName == item.bottleName }
    }
    private var verdict: GamePageCopy.Verdict { GamePageCopy.verdict(entry, myChip: state.machineChip) }
    private var willDo: [GamePageCopy.WillDo] {
        GamePageCopy.willDo(entry, recipe: fixRecipe, applied: fixApplied, bottleRenderer: bottle?.settings.renderer ?? .dxvk,
                            explicit: bottle?.settings.rendererExplicit ?? false, gameOverride: state.rendererOverride(for: item),
                            needsDirect3D12: item.installed && entry?.nativeVulkan != true && state.programNeedsDirect3D12(item))
    }
    private var engineName: String? { bottle.flatMap { state.engine(for: $0) }?.displayName }

    private var storeAppID: Int? { item.steamAppID }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        let width = max(0, min(geometry.size.width - 64, 1320))
                        if width >= 860 {
                            HStack(alignment: .top, spacing: 32) {
                                GameMediaGallery(item: item, details: storeDetails, width: (width - 32) * 0.58,
                                                 selectedURL: $selectedGalleryURL, choseImage: $choseGalleryImage)
                                    .frame(width: (width - 32) * 0.58)
                                overview(scroll: scroll)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            overview(scroll: scroll)
                            GameMediaGallery(item: item, details: storeDetails, width: width,
                                             selectedURL: $selectedGalleryURL, choseImage: $choseGalleryImage)
                        }
                        aboutGame
                        if bottle != nil {
                            advanced.id("game-settings")
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: 1384, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(BottleBackdrop())
        .navigationTitle(state.displayTitle(item))
        .task(id: storeAppID) {
            storeDetails = nil
            expandedDescription = false
            guard let appID = storeAppID else { loadingDetails = false; return }
            loadingDetails = true
            let language: SteamGameDetailsStore.Language = Locale.preferredLanguages.first?.hasPrefix("fr") == true ? .french : .english
            let details = await SteamGameDetailsStore.shared.details(appID: appID, language: language)
            guard !Task.isCancelled else { return }
            storeDetails = details
            loadingDetails = false
        }
        .task(id: "\(item.id)|\(item.installed)|\(item.installedOnMac)|cloud") {
            cloudSetup = nil; cloudSetupAsked = false
            guard item.source == .gog, item.installedAnywhere else { return }
            cloudSetup = await state.gogCloudSetup(for: item)
            cloudSetupAsked = true
        }
        // How much room it takes: the store's estimate before an install, the folders after.
        // All three at once, each shown as it comes: a store's answer takes seconds.
        .task(id: "\(item.id)|\(item.installed)|\(item.installedOnMac)") {
            sizes = nil; windowsEstimate = nil; macEstimate = nil; estimatesDone = false
            let item = item
            let wantsWindows = !item.installed && [.gog, .epic, .steam].contains(item.source)
            let wantsMac = hasMacVersion && !item.installedOnMac
            // A size saved earlier shows at once; one older than a day is checked again quietly.
            if wantsWindows { windowsEstimate = state.savedEstimate(for: item, mac: false) }
            if wantsMac { macEstimate = state.savedEstimate(for: item, mac: true) }
            await withTaskGroup(of: Void.self) { group in
                if item.installedAnywhere {
                    group.addTask { @MainActor in sizes = await state.installedSizes(for: item) }
                }
                if wantsWindows, windowsEstimate == nil || state.estimateIsStale(for: item, mac: false) {
                    let refresh = windowsEstimate != nil
                    group.addTask { @MainActor in
                        if let fresh = await state.downloadEstimate(for: item, mac: false, refresh: refresh) { windowsEstimate = fresh }
                    }
                }
                if wantsMac, macEstimate == nil || state.estimateIsStale(for: item, mac: true) {
                    let refresh = macEstimate != nil
                    group.addTask { @MainActor in
                        if let fresh = await state.downloadEstimate(for: item, mac: true, refresh: refresh) { macEstimate = fresh }
                    }
                }
            }
            estimatesDone = true
        }
    }

    private func overview(scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(state.displayTitle(item))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let macBuild {
                macBlock(macBuild)
            } else if item.macListed, item.source == .gog || item.source == .epic {
                storeMacBlock
            } else if let outdated = GamePageCopy.outdatedMacBuild(appInfo: item.steamAppID.flatMap { state.macAppInfoByAppID[$0] }, entry: entry) {
                Label(L(outdated), systemImage: "apple.logo").font(.callout).foregroundStyle(.secondary)
            }
            verdictBlock
            HStack(alignment: .top, spacing: 10) {
                playRow.frame(maxWidth: .infinity, alignment: .leading)
                if bottle != nil {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            showAdvanced = true
                            scroll.scrollTo("game-settings", anchor: .top)
                        }
                    } label: {
                        Image(systemName: "gearshape.fill").font(.title3.weight(.semibold))
                            .frame(width: 24, height: 24).padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .accessibilityLabel(L("Game settings"))
                    .help(L("Game settings"))
                }
            }
            if item.installed, !blocked { willDoCard }
            libraryInfo
        }
    }

    /// A GOG game's own settings, one row each like the rest of the page: comet (achievements and
    /// stats), cloud saves, which launch task Play runs, and an update for a game gogdl installed.
    @ViewBuilder private func gogSettings(_ game: GOGStore.InstalledGame) -> some View {
        let cometOff = state.gogSettings.cometOff[game.id]
        HStack(alignment: .top, spacing: 12) {
            Text(L("Achievements")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Toggle(L("Achievements and stats (comet)"), isOn: Binding(
                    get: { cometOff == nil }, set: { state.gogSetComet($0, for: game.id) }))
                    .toggleStyle(.checkbox).disabled(!state.gogSignedIn)
                Text(cometOff == GOGSettings.crashedWithComet
                     ? L("Turned off after the game closed at once with comet running and then started fine without it. Turn it back on to try again.")
                     : L("comet stands in for GOG Galaxy while the game runs, so achievements, stats and play time reach your GOG account. If the game won't start with it, Highball starts it again without."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack(alignment: .top, spacing: 12) {
            Text(L("Cloud saves")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Toggle(L("Sync saves with GOG"), isOn: Binding(
                    get: { !state.gogSettings.cloudSavesOff.contains(game.id) }, set: { state.gogSetCloudSaves($0, for: game.id) }))
                    .toggleStyle(.checkbox).disabled(!state.gogSignedIn)
                Text(L("Saves come down from GOG's cloud before Play and go back up when the game ends. If both copies changed, Highball asks which one wins."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !state.gogSignedIn {
                    Button(L("Connect GOG")) { state.showGOGSignIn = true }.controlSize(.small)
                }
            }
        }
        if !game.launchChoices.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Text(L("Launch option")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading).padding(.top, 4)
                Picker("", selection: Binding(
                    get: { state.gogSettings.launchChoice[game.id] ?? -1 },
                    set: { state.gogSetLaunchChoice($0 < 0 ? nil : $0, for: game.id) })) {
                    Text(L("GOG's default")).tag(-1)
                    ForEach(Array(game.launchChoices.enumerated()), id: \.offset) { index, task in
                        Text(verbatim: task.name ?? task.path ?? "").tag(index)
                    }
                }.labelsHidden().frame(maxWidth: 360)
            }
        }
        if state.gogStore.hasManifest(game) {
            HStack(alignment: .top, spacing: 12) {
                Text(L("Version")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(verbatim: game.buildID.map { String(format: L("GOG build %@"), $0) } ?? "GOG").font(.callout)
                        Button(L("Update from GOG")) { state.gogUpdate(item) }.controlSize(.small).disabled(state.busy)
                    }
                    Text(L("Downloads only what changed since this build. Nothing happens when it is already the newest."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var libraryInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(L("Source"), item.source == .steam ? "Steam" : item.source == .epic ? "Epic Games"
                : item.source == .gog ? "GOG" : item.source == .battlenet ? "Battle.net" : L("Windows program"))
            // Every game says how much room it takes: what an install needs before, what is on disk after.
            if item.source != .pin || item.installed {
                row(hasMacVersion ? L("Size (Windows)") : L("Size"), windowsSize)
            }
            if hasMacVersion {
                row(L("Size (Mac)"), macSize)
            }
            if item.source == .steam || item.source == .epic || (item.source == .gog && item.installedAnywhere) { cloudSavesRow }
            if let saves = sizes?.saves {
                row(item.source == .steam ? L("Steam Cloud saves") : L("Saves"), Self.bytes(saves))
            }
            if let played = item.lastPlayed {
                row(L("Last played"), played.formatted(date: .abbreviated, time: .shortened))
            }
            // Hiding keeps the game and its settings, it only leaves the library's grid and the
            // installed row (highball#445).
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(L("Library")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                if state.isHidden(item) {
                    Text(L("Hidden")).font(.callout)
                    Button(L("Show in library")) { state.setHidden(false, for: item) }.controlSize(.small)
                } else {
                    Button(L("Hide from library")) { state.setHidden(true, for: item) }.controlSize(.small)
                        .help(L("Takes the game out of the library without touching it. The Hidden filter lists it again."))
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(HB.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HB.cardStroke))
    }

    @ViewBuilder private var aboutGame: some View {
        if let details = storeDetails {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(L("About this game")).font(.title2.bold())
                    Spacer()
                    Link(destination: details.storeURL) { Label(L("View on Steam"), systemImage: "arrow.up.right") }
                        .font(.callout)
                }
                if !details.summary.isEmpty {
                    Text(verbatim: details.summary).font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if !details.description.isEmpty, details.description != details.summary {
                    DisclosureGroup(isExpanded: $expandedDescription) {
                        Text(verbatim: details.description).font(.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                    } label: {
                        // The words open it too, not only the chevron: with a plain label macOS
                        // toggles a DisclosureGroup from its chevron alone, and players clicked
                        // "Read more" and saw nothing happen.
                        Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expandedDescription.toggle() } } label: {
                            HStack(spacing: 8) {
                                Text(L("Read more"))
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !details.genres.isEmpty {
                    Text(verbatim: details.genres.joined(separator: " · "))
                        .font(.callout.weight(.medium)).foregroundStyle(HB.amber)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 40) { storeFacts(details) }
                    VStack(alignment: .leading, spacing: 16) { storeFacts(details) }
                }
                Text(L("Game information and screenshots from Steam.")).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(HB.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(HB.cardStroke))
        } else if storeAppID != nil {
            HStack(spacing: 10) {
                if loadingDetails {
                    ProgressView().controlSize(.small)
                    Text(L("Loading game information…")).font(.callout).foregroundStyle(.secondary)
                } else {
                    if let appID = storeAppID, let url = URL(string: "https://store.steampowered.com/app/\(appID)/") {
                        Link(L("View on Steam"), destination: url).font(.callout)
                    }
                }
            }
        }
    }

    @ViewBuilder private func storeFacts(_ details: SteamGameDetails) -> some View {
        if !details.developers.isEmpty { storeFact(L("Developer"), details.developers.joined(separator: ", ")) }
        if !details.publishers.isEmpty { storeFact(L("Publisher"), details.publishers.joined(separator: ", ")) }
        if let date = details.releaseDate { storeFact(L("Release date"), date) }
    }

    private func storeFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.tertiary)
            Text(verbatim: value).font(.callout).textSelection(.enabled)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var verdictColor: Color {
        switch entry?.status {
        case "verified-local": return HB.good
        case let s? where s.hasPrefix("blocked-"): return HB.bad
        case nil: return .secondary
        default: return HB.amber
        }
    }

    private var verdictBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(verdictColor).frame(width: 8, height: 8).padding(.top, 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(verdict.headline).font(.title3.weight(.semibold))
                if let detail = verdict.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var macBuild: GamePageCopy.MacBuild? {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        return GamePageCopy.macBuild(state.macSteamBuild(for: item), entry: entry, myChip: state.machineChip, macOS: os)
    }

    /// A native Mac build on Steam: what it is, why it matters, what it needs. Above the verdict,
    /// which is about the Windows build.
    private func macBlock(_ copy: GamePageCopy.MacBuild) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "apple.logo").foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(copy.headline).font(.callout.weight(.semibold))
                Text(copy.detail).font(.callout).foregroundStyle(.secondary)
                // This Mac only next to what the build asks for: the verdict below already names the chip.
                if let requirements = copy.requirements {
                    Text(requirements).font(.callout).foregroundStyle(.secondary)
                    Text(copy.yourMac).font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    macButton
                    Text(copy.source).font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(HB.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.35)))
    }

    /// A Mac version GOG's or Epic's catalog lists (LibraryItem.macListed): the purchase includes
    /// it, and the store's own app or site hands it out. Listed is not proven: an old 32-bit Mac
    /// build no longer runs, and neither catalog says which.
    private var storeMacBlock: some View {
        let gog = item.source == .gog
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "apple.logo").foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(gog ? L("Your GOG purchase includes a Mac version") : L("Your Epic purchase includes a Mac version"))
                    .font(.callout.weight(.semibold))
                Text(gog ? L("GOG lists a Mac build of this game. It runs without Windows or Wine, though some older Mac versions no longer start on current macOS.")
                         : L("Epic lists a Mac build of this game. It runs without Windows or Wine, though some older Mac versions no longer start on current macOS."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if gog, let game = item.gogID.flatMap({ state.gogMacInstalled[$0] }) {
                    if let note = Self.archNote(game.arch) {
                        Text(note).font(.callout).foregroundStyle(game.arch == .only32Bit ? HB.warn : .secondary)
                    }
                    HStack(spacing: 10) {
                        Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([game.app ?? game.folder]) }
                        Button(L("Move the Mac version to the Trash")) { state.gogTrashMac(item) }.disabled(state.busy)
                    }
                    .controlSize(.small).padding(.top, 2)
                } else if gog {
                    // With the Windows build installed the play row offers that one; the Mac one is here.
                    if item.installed {
                        HStack(spacing: 8) {
                            Button(L("Install the Mac version")) { state.installOnMac(item) }.controlSize(.small).disabled(state.busy)
                            estimateText(macEstimate)
                        }
                        .padding(.top, 2)
                    }
                } else if let folder = state.macFolder(for: item) {
                    // Epic's Mac build, installed through legendary.
                    if let note = Self.archNote(MacBinaryArch.ofApp(at: folder)) {
                        Text(note).font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        Button(L("Remove the Mac version…")) { state.pendingEpicMacUninstall = item }.disabled(state.busy)
                    }
                    .controlSize(.small).padding(.top, 2)
                } else if item.installed {
                    // Epic keeps one build per game: from the Windows one, a switch.
                    HStack(spacing: 8) {
                        Button(L("Switch to the Mac version…")) { state.installOnMac(item) }.controlSize(.small).disabled(state.busy)
                        estimateText(macEstimate)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(HB.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.35)))
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    /// How the game saves, said as what it does, with an explanation a click away: Steam Cloud's
    /// and Epic's cloud from their own data, GOG's per installed version from its settings.
    private var cloudSavesRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L("Cloud saves")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(cloudSaveLines, id: \.self) { Text($0).font(.callout).fixedSize(horizontal: false, vertical: true) }
            }
            Button { showCloudHelp = true } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(L("How this game's saves sync"))
                .popover(isPresented: $showCloudHelp, arrowEdge: .trailing) { cloudSavesHelp }
        }
    }

    private var cloudSaveLines: [String] {
        switch item.source {
        case .steam:
            return [item.steamAppID.map(state.steamCloudAppIDs.contains) == true
                    ? L("Steam syncs this game's saves with Steam Cloud, for whichever account plays it.")
                    : L("This game keeps its saves on this Mac.")]
        case .epic:
            return [state.epicOwned.first { $0.app_name == item.epicAppName }?.cloudSaves == true
                    ? L("Epic's cloud keeps this game's saves when Epic's own launcher plays it. Played from Highball, they stay on this Mac.")
                    : L("This game keeps its saves on this Mac.")]
        default: break
        }
        guard cloudSetupAsked else { return [L("Checking…")] }
        guard let setup = cloudSetup, let id = item.gogID else { return [L("Highball could not reach GOG to see how this game saves.")] }
        let syncing = !state.gogSettings.cloudSavesOff.contains(id)
        func line(_ folders: [GOGSaves.Location], synced: String, own: String) -> String {
            folders.isEmpty ? own : syncing ? synced : L("Kept on this Mac: Sync saves with GOG, under Game settings, syncs them.")
        }
        var lines: [String] = []
        if item.installed {
            lines.append(line(setup.windows, synced: L("The Windows version's saves sync with GOG's cloud before and after you play."),
                              own: L("The game handles the Windows version's saves; some games sync them with GOG's cloud themselves while comet runs.")))
        }
        if item.installedOnMac {
            lines.append(line(setup.mac, synced: L("The Mac version's saves sync with GOG's cloud before and after you play."),
                              own: L("The game handles the Mac version's saves; some games sync them with GOG's cloud themselves while comet runs.")))
        }
        return lines
    }

    /// How the game's store syncs saves; for GOG, the two ways and the folders this game's covers.
    @ViewBuilder private var cloudSavesHelp: some View {
        switch item.source {
        case .steam:
            VStack(alignment: .leading, spacing: 10) {
                Text(L("How Steam Cloud works")).font(.headline)
                Text(L("Steam syncs a game's saves with Steam Cloud itself, before and after you play, for the account signed in to Steam. Highball starts the game through Steam, so nothing changes. The Steam Cloud saves row is Steam's copy on this Mac."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(16).frame(width: 380, alignment: .leading)
        case .epic:
            VStack(alignment: .leading, spacing: 10) {
                Text(L("How Epic's cloud saves work")).font(.headline)
                Text(L("Epic's launcher syncs a game's saves with Epic's cloud when the game sets a cloud save folder. Highball plays Epic games through legendary, and their saves stay on this Mac."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(16).frame(width: 380, alignment: .leading)
        default:
            gogCloudSavesHelp
        }
    }

    /// The two ways GOG syncs saves, and the folders this game's file sync covers.
    private var gogCloudSavesHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("How saves sync with GOG")).font(.headline)
            Text(L("GOG syncs saves in one of two ways, chosen per game and per version.")).font(.callout)
            Text(L("Folder sync: GOG names the folders a game saves in, and Highball copies them to and from GOG's cloud before and after you play, as GOG Galaxy does. When both copies changed, Highball asks which one to keep."))
                .font(.callout).foregroundStyle(.secondary)
            Text(L("The game's own sync: some games send their saves to GOG's cloud themselves, through GOG's game kit. With Highball that works while comet runs beside the game, and the game says so when it syncs, as Cyberpunk 2077 does."))
                .font(.callout).foregroundStyle(.secondary)
            let folders = (cloudSetup.map { (item.installed ? $0.windows : []) + (item.installedOnMac ? $0.mac : []) } ?? []).map(\.template)
            if !folders.isEmpty {
                Text(L("Folders this game syncs")).font(.caption.weight(.semibold)).padding(.top, 2)
                ForEach(folders, id: \.self) { Text(verbatim: $0).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }
        .padding(16).frame(width: 380, alignment: .leading)
    }

    /// A native Mac version exists: Steam's (MacSteamBuild), or one GOG or Epic lists.
    private var hasMacVersion: Bool { state.offersMacVersion(item) }

    /// The Windows build (or the program): on disk when installed, the store's figure before.
    private var windowsSize: String {
        if item.installed {
            if item.sizeOnDisk > 0 { return String(format: L("Uses %@ of space"), Self.bytes(item.sizeOnDisk)) }
            if let game = sizes?.game { return String(format: L("Uses %@ of space"), Self.bytes(game)) }
            return sizes == nil ? L("Measuring…") : L("Unknown")
        }
        return Self.beforeInstall(windowsEstimate, done: estimatesDone)
    }

    private var macSize: String {
        if item.installedOnMac {
            if let mac = sizes?.macGame { return String(format: L("Uses %@ of space"), Self.bytes(mac)) }
            return sizes == nil ? L("Measuring…") : L("Unknown")
        }
        return Self.beforeInstall(macEstimate, done: estimatesDone)
    }

    /// "Takes 2.18 GB of space (301.8 MB to download)" before an install: the room on the Mac
    /// first, the compressed transfer second. "Checking…" while the store is
    /// asked, "Unknown" when it could not say, never a blank.
    static func beforeInstall(_ estimate: DownloadEstimate?, done: Bool) -> String {
        guard let estimate, estimate.disk != nil || estimate.download != nil else { return done ? L("Unknown") : L("Checking…") }
        switch (estimate.disk, estimate.download) {
        case let (disk?, download?): return String(format: L("Takes %@ of space (%@ to download)"), bytes(disk), bytes(download))
        case let (disk?, nil): return String(format: L("Takes %@ of space"), bytes(disk))
        case let (nil, download?): return String(format: L("%@ to download"), bytes(download))
        default: return L("Unknown")
        }
    }

    /// The same figure beside an install button, so the choice is made knowing the room it takes.
    @ViewBuilder private func estimateText(_ estimate: DownloadEstimate?) -> some View {
        if let estimate, estimate.download != nil || estimate.disk != nil {
            Text(Self.beforeInstall(estimate, done: true)).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// What an installed Mac build's executable says about running here (MacBinaryArch).
    static func archNote(_ arch: MacBinaryArch) -> String? {
        switch arch {
        case .native: L("Built for Apple silicon: runs natively.")
        case .intelOnly: L("Built for Intel Macs: runs through Rosetta.")
        case .only32Bit: L("A 32-bit build, which current macOS can't run. Play the Windows version instead.")
        case .unknown: nil
        }
    }

    /// Only when the Windows build is the installed one: otherwise the play row already offers
    /// the Mac build (Play on Mac, Install on Mac).
    @ViewBuilder private var macButton: some View {
        if item.installed, !item.installedOnMac {
            Button(state.steamForMacInstalled ? L("Install on Mac") : L("Get Steam for Mac")) { state.installOnMac(item) }
                .controlSize(.small)
        }
    }

    private func primaryActionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity).frame(height: 24).padding(.vertical, 8)
    }

    private var playRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let running {
                Button { state.stopSession(running) } label: { primaryActionLabel(L("Stop"), symbol: "stop.fill") }.buttonStyle(.bordered).controlSize(.large)
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    Text(ActivityText.minutes(since: running.started, now: ctx.date)
                            .map { String(format: L("Running for %d min"), $0) } ?? L("Running"))
                        .font(.callout).foregroundStyle(HB.good)
                }
            } else if state.prefersMacBuild(item) {
                // The native build first; a Windows copy in a bottle stays one click away.
                Button { commitTypedArguments(); state.playOnMac(item) } label: {
                    primaryActionLabel(L("Play on Mac"), symbol: "play.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(HB.amber)
                if item.installed {
                    Button(L("Play the Windows version")) { commitTypedArguments(); state.play(item, windowsBuild: true) }
                        .controlSize(.large).disabled(state.busy || blocked)
                } else {
                    Text(item.source == .steam ? L("Starts through Steam for Mac.") : L("Opens the Mac version, without Wine."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if item.installed {
                Button { commitTypedArguments(); state.play(item) } label: {
                    primaryActionLabel(L("Play"), symbol: "play.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(HB.amber)
                .disabled(state.busy || blocked)
                if item.installedOnMac {
                    // The row put the Windows build first (a Mac build missing content); the Mac one stays a click away.
                    Button(L("Play on Mac")) { commitTypedArguments(); state.playOnMac(item) }.controlSize(.large)
                } else {
                    Text(!blocked ? L("Highball will ask how it went when you finish.")
                         : entry?.status == "blocked-publisher" ? L("Its publisher stops it on macOS on purpose.")
                         : L("Its anti-cheat does not run on macOS."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if item.source == .gog || item.source == .epic, item.macListed, !item.installedOnMac {
                // A Mac version is listed: that's the install on offer, the Windows one a click away.
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 10) {
                        Button { state.installOnMac(item) } label: { primaryActionLabel(L("Install the Mac version"), symbol: "apple.logo") }
                            .buttonStyle(.borderedProminent).controlSize(.large).tint(HB.amber).disabled(state.busy)
                        Text(String(format: L("Goes into %@, outside every environment."), "~/Applications/Highball Games"))
                            .font(.callout).foregroundStyle(.secondary)
                        estimateText(macEstimate)
                    }
                    HStack(spacing: 6) {
                        Button(L("Install the Windows version instead")) { state.install(item) }
                            .buttonStyle(.link).font(.callout).disabled(state.busy)
                        estimateText(windowsEstimate)
                    }
                }
            } else if item.source == .epic, item.installedOnMac {
                // Epic keeps one build per game, and this Mac one does not run (32-bit): the way
                // out is the Windows build, which takes its place.
                Text(L("This Mac version is 32-bit, which current macOS can't run.")).font(.callout).foregroundStyle(HB.warn)
                Button(L("Switch to the Windows version…")) { state.pendingEpicWindowsSwitch = item }
                    .controlSize(.large).disabled(state.busy)
            } else if item.source == .epic || item.source == .gog {
                Button { state.install(item) } label: { primaryActionLabel(L("Install"), symbol: "arrow.down") }.buttonStyle(.borderedProminent).controlSize(.large).tint(HB.amber)
                    .disabled(state.busy)
                Text(String(format: L("Installs into %@."), state.defaultBottle?.name ?? L("your environment"))).font(.callout).foregroundStyle(.secondary)
                estimateText(windowsEstimate)
            } else if item.source == .steam, !steamHasManifest, state.macSteamBuild(for: item) != nil {
                // A native build exists: that's the install on offer; the Windows one is the
                // way around it, not the default.
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 10) {
                        Button { state.installOnMac(item) } label: {
                            primaryActionLabel(state.steamForMacInstalled ? L("Install on Mac") : L("Get Steam for Mac"), symbol: "apple.logo")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).tint(HB.amber)
                        Text(state.steamForMacInstalled ? L("Steam for Mac asks where to put it.")
                                                        : L("The Mac build installs through Steam for Mac."))
                            .font(.callout).foregroundStyle(.secondary)
                        estimateText(macEstimate)
                    }
                    HStack(spacing: 6) {
                        Button(L("Install the Windows version instead")) { state.install(item) }
                            .buttonStyle(.link).font(.callout).disabled(state.busy || blocked)
                            .help(L("For when the Mac build lags behind or a mod needs the Windows one."))
                        estimateText(windowsEstimate)
                    }
                }
            } else if item.source == .steam, !steamHasManifest {
                // Owned, never installed here (highball#199): Steam's own dialog takes it from here.
                Button { state.install(item) } label: { primaryActionLabel(L("Install"), symbol: "arrow.down") }.buttonStyle(.borderedProminent).controlSize(.large).tint(HB.amber)
                    .disabled(state.busy)
                Text(L("Steam asks where to put it.")).font(.callout).foregroundStyle(.secondary)
                estimateText(windowsEstimate)
            } else if item.source == .steam {
                Text(L("Not downloaded yet. Install it from the Steam window.")).font(.callout).foregroundStyle(.secondary)
                if let b = bottle ?? state.defaultBottle { Button(L("Open Steam")) { state.showSteam(in: b) }.controlSize(.large) }
            } else {
                Text(L("Not installed.")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func localizedWillDo(_ line: GamePageCopy.WillDo) -> String {
        guard let recipe = fixRecipe, recipe.isOptIn else { return line.text }
        if line.text == "Keep the \(recipe.title) fix you applied under Game settings" {
            return String(format: L("Keep the %@ fix you applied under Game settings"), recipe.title)
        }
        if line.text == "Leave the optional \(recipe.title) fix alone; it is under Game settings for when the notes say your Mac needs it" {
            return String(format: L("Leave the optional %@ fix alone; it is under Game settings for when the notes say your Mac needs it"), recipe.title)
        }
        return line.text
    }

    private var willDoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Next to Play on Mac, "Play" alone would read as the Mac build's.
            HB.eyebrow(state.prefersMacBuild(item) ? L("When you play the Windows version, Highball will") : L("When you press Play, Highball will"))
            ForEach(Array(willDo.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: line.done ? "checkmark" : (line.cost == nil ? "checkmark" : "hourglass"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(line.cost == nil || line.done ? HB.good : HB.amber)
                        .frame(width: 14)
                    Text(localizedWillDo(line)).font(.callout)
                    if let cost = line.cost {
                        Text(cost).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if let held = GamePageCopy.rowRendererHeldBack(entry, bottleRenderer: bottle?.settings.renderer ?? .dxvk,
                                                           explicit: bottle?.settings.rendererExplicit ?? false,
                                                           gameOverride: state.rendererOverride(for: item),
                                                           needsDirect3D12: item.installed && state.programNeedsDirect3D12(item)),
               let engine = bottle.flatMap({ state.engine(for: $0) }), held.availability(in: engine) == .available {
                Button(String(format: L("Use %@ for this game"), GamePageCopy.plainName(held))) {
                    state.setRendererOverride(held, for: item.id)
                }
                .controlSize(.small).padding(.top, 2)
            }
            HStack(spacing: 6) {
                Text(entry == nil ? L("No row in the compatibility database yet.") : L("From the open compatibility database."))
                    .font(.caption).foregroundStyle(.secondary)
                if entry != nil {
                    Button(L("Why these settings?")) { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { showWhy.toggle() } }
                        .buttonStyle(.link).font(.caption)
                }
            }
            if showWhy { whyExplanation }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(HB.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HB.cardStroke))
    }

    /// The explanation, and the way out: the environment's own settings are one click away.
    private var whyExplanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Why these settings")).font(.headline)
            if let notes = entry?.notes { Text(notes).font(.callout) }
            if let p = entry?.provenance {
                Text(p).font(.caption).foregroundStyle(.secondary)
            }
            if let results = entry?.rendererResults, !results.isEmpty {
                Divider()
                ForEach(results.keys.sorted(), id: \.self) { key in
                    if let r = results[key] {
                        Text("\(key.uppercased()): \(r.verdict)\(r.detail.map { ", \($0)" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Text(L("To play with the environment's own graphics mode instead, change it under Game settings below; Highball then leaves it alone for every game in that environment."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 14) {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    if let bottle {
                        if entry?.nativeVulkan == true {
                            row(L("Graphics mode"), L("Does not apply: this game draws with Vulkan directly, not through any Direct3D layer."))
                        } else {
                            if let engine = state.engine(for: bottle) {
                                HStack(alignment: .top, spacing: 12) {
                                    Text(L("Mode for this game")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading).padding(.top, 4)
                                    Picker("", selection: Binding(
                                        get: { state.rendererOverride(for: item)?.rawValue ?? "" },
                                        set: { state.setRendererOverride(Renderer(rawValue: $0), for: item.id) })) {
                                        Text(L("Environment's mode")).tag("")
                                        // Shipped modes, licence accepted or not: a pick that still
                                        // needs Apple's licence is asked for at Play (highball#138).
                                        ForEach(Renderer.allCases.filter { $0.availability(in: engine) != .notShipped }, id: \.self) { r in
                                            Text(GamePageCopy.plainName(r)).tag(r.rawValue)
                                        }
                                    }.labelsHidden().frame(maxWidth: 360)
                                }
                            }
                            HStack(alignment: .top, spacing: 12) {
                                Text(L("Environment's mode")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading).padding(.top, 4)
                                GraphicsModePicker(bottle: bottle)
                            }
                        }
                        if let emulated = state.displayModeEmulation(for: item) {
                            HStack(alignment: .top, spacing: 12) {
                                Text(L("Display mode")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Toggle(L("Emulate display mode changes"), isOn: Binding(
                                        get: { emulated }, set: { state.setDisplayModeEmulation($0, for: item) }))
                                        .toggleStyle(.checkbox)
                                    Text(L("For a game that opens small, off-centre, or refuses its fullscreen mode. The Mac cannot switch its display for it, so Wine pretends and scales the picture instead. A fix from the database may have set this already."))
                                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        let stored = state.displayChoice(for: item) ?? ""
                        let monitors = Monitor.connected()
                        HStack(alignment: .top, spacing: 12) {
                            Text(L("Display")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading).padding(.top, 4)
                            VStack(alignment: .leading, spacing: 4) {
                                Picker("", selection: Binding(
                                    get: { stored },
                                    set: { state.setDisplay($0.isEmpty ? nil : $0, for: item) })) {
                                    Text(L("Main display")).tag("")
                                    ForEach(monitors) { monitor in Text(monitor.name).tag(monitor.id) }
                                    if !stored.isEmpty, !monitors.contains(where: { $0.id == stored }) {
                                        Text(L("Disconnected display")).tag(stored)
                                    }
                                }.labelsHidden().frame(maxWidth: 360)
                                Text(L("Highball moves the game's window here after it opens. Works best for windowed and borderless games. Needs Accessibility permission for Highball."))
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if item.source == .steam || item.source == .epic || item.source == .gog {
                            HStack(alignment: .top, spacing: 12) {
                                Text(L("Launch arguments")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 4) {
                                    TextField("", text: $argsText, prompt: Text(L("None")))
                                        .font(.body.monospaced()).frame(maxWidth: 360)
                                        .onSubmit { state.setLaunchArguments(argsText, for: item) }
                                    Text(L("Passed to the game on every Play from Highball, after any its fix adds. Quote arguments that contain spaces."))
                                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .onAppear {
                                guard !argsLoaded else { return }
                                argsText = ArgumentLine.join(state.launchArguments(for: item)); argsLoaded = true
                            }
                            .onDisappear { state.setLaunchArguments(argsText, for: item) }
                        }
                        if item.source == .gog, let game = state.gogInstalled(item, in: bottle) {
                            gogSettings(game)
                        }
                        // The engine is the environment's, so the page says so and can change it
                        // through the same switch page as the environment's settings, which lists
                        // every program that moves along (highball#262: an engine shown here that
                        // could not be changed read as a dead end).
                        let offered = state.offeredEngines(for: bottle)
                        HStack(alignment: .top, spacing: 12) {
                            Text(L("Engine")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading).padding(.top, offered.count > 1 ? 4 : 0)
                            VStack(alignment: .leading, spacing: 4) {
                                if offered.count > 1 {
                                    Picker("", selection: Binding(
                                        get: { bottle.settings.engineID },
                                        set: { newID in
                                            guard newID != bottle.settings.engineID else { return }
                                            state.engineTransition = AppState.EngineTransition(bottleName: bottle.name, targetID: newID)
                                        })) {
                                        ForEach(offered, id: \.id) { e in
                                            Text(verbatim: e.missing ? "\(e.label) (\(L("missing")))" : e.installed ? e.label : "\(e.label) (\(L("download")))").tag(e.id)
                                        }
                                    }.labelsHidden().frame(maxWidth: 360).disabled(state.busy)
                                } else {
                                    Text(verbatim: (state.engine(for: bottle)?.displayName).map { "\($0) · \(bottle.settings.engineID)" } ?? bottle.settings.engineID)
                                        .font(.callout)
                                }
                                Text(String(format: L("The engine belongs to the environment '%@', so a change here applies to every game in it. The page that opens lists them before anything moves."), bottle.name))
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        // Variables a fix scoped to this game (highball#198): the environment's own
                        // editor shows only the environment-wide ones, so the page says what this
                        // game gets on top of them.
                        let scoped = bottle.settings.environment(forGame: entry?.id)
                        if !scoped.isEmpty {
                            HStack(alignment: .top, spacing: 12) {
                                Text(L("This game's variables")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(scoped.keys.sorted(), id: \.self) { key in
                                        Text("\(key)=\(scoped[key] ?? "")").font(.callout.monospaced()).textSelection(.enabled)
                                    }
                                    Text(L("Set by this game's fix, applied to its launches only."))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(L("Environment")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            Text(bottle.name).font(.callout)
                            NavigationLink(L("Environment settings…"), value: EnvironmentSettingsDestination(name: bottle.name)).controlSize(.small)
                            // An Epic game lives where its folder is, so it can move alone, where the
                            // engine switch moves every game of the environment (highball#566).
                            if item.source == .epic, item.installed, state.bottles.count > 1 {
                                Menu(L("Move to…")) {
                                    ForEach(state.bottles.filter { $0.name != bottle.name }, id: \.name) { other in
                                        Button(other.name) { state.moveEpicGame(item, to: other) }
                                    }
                                }
                                .controlSize(.small).fixedSize().disabled(state.busy || running != nil)
                                .help(L("Moves this game's folder into another environment, where it plays with that environment's engine and settings. Its other games stay where they are. Saves the game keeps in the environment's user folders stay behind, unless Epic keeps them in the cloud."))
                            }
                        }
                        // Another copy plays from its own environment; once played there, the
                        // tile follows it (highball#264).
                        ForEach(item.otherBottles, id: \.self) { other in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(L("Also installed in")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                                Text(other).font(.callout)
                                Button(L("Play there")) { commitTypedArguments(); state.play(item.homed(in: other)) }.controlSize(.small)
                            }
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(L("Files")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            if let folder = state.programFolder(for: item) {
                                Button(L("Show the game's folder")) { NSWorkspace.shared.open(folder) }.controlSize(.small)
                                    .help(L("Opens the game's own folder in the Finder, where mods and config files go."))
                            }
                            Button(L("Show the Windows drive")) { NSWorkspace.shared.open(bottle.driveC) }.controlSize(.small)
                            if item.installed {
                                Button(L("Uninstall…"), role: .destructive) { state.askUninstall(item) }.controlSize(.small)
                                    .disabled(state.uninstallWaitsFor(item) != nil)
                                    .help(state.uninstallWaitsFor(item).map { String(format: L("Available once “%@” has finished."), $0) }
                                          ?? L("Steam and the Epic tools do their own uninstalling, so their libraries stay right."))
                            }
                            if MacAppStub.existing(for: item.title) != nil {
                                Button(L("Remove the Mac app")) { state.removeMacApp(title: item.title) }.controlSize(.small)
                                    .help(L("Moves this game's Mac app in ~/Applications/Highball to the Trash."))
                            } else if PlayLink.target(for: item) != nil {
                                Button(L("Make a Mac app…")) { state.makeMacApp(for: item) }.controlSize(.small)
                                    .help(L("A real app in ~/Applications/Highball with the game's own icon, for the Dock, Spotlight or Launchpad. It starts the game without opening Highball first."))
                            }
                        }
                        if let log = state.lastLaunchLog(for: item) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(L("Log")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                                Button(L("Show the last launch log")) { NSWorkspace.shared.open(log) }.controlSize(.small)
                                    .help(log.lastPathComponent)
                            }
                        }
                        if let fixRecipe, item.installed {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(L("Fix")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                                Button(fixApplied ? String(format: L("Re-apply the %@ fix"), fixRecipe.title) : String(format: L("Apply the %@ fix now"), fixRecipe.title)) {
                                    state.applyRecipe(fixRecipe.id, to: bottle)
                                }
                                .controlSize(.small).disabled(state.busy)
                            }
                        }
                    }
                }
                .padding(.top, 10)
            } label: {
                // The whole row toggles, not only the chevron.
                Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { showAdvanced.toggle() } } label: {
                    HStack(spacing: 8) {
                        Text(L("Game settings")).font(.headline)
                        Text(L("graphics mode · engine · environment · files")).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }
}
