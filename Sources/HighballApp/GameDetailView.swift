import SwiftUI
import HighballKit

/// Media and store copy alongside the existing launch plan; game settings stay inline below.
struct GameDetailView: View {
    @Environment(AppState.self) private var state
    let passedItem: LibraryItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var storeDetails: SteamGameDetails?
    @State private var accountNote: SteamAccounts.GameNote?
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
        // Who installed the game, and whether Steam is signed in to another account that may not
        // have it. Only the signed-in account is read again, every few seconds: switching accounts
        // happens in Steam, and the install records and accounts are already in the app's state.
        .task(id: item.id) {
            accountNote = nil
            guard item.source == .steam, let appID = item.steamAppID,
                  let bottle = state.bottles.first(where: { $0.name == item.bottleName }) else { return }
            while !Task.isCancelled {
                let signedIn = await Task.detached { SteamAccounts.signedIn(bottleURL: bottle.url) }.value
                let note = SteamAccounts.note(installedBy: state.gamesByBottle[bottle.name]?.first { $0.appid == appID }?.lastOwner,
                                              accounts: state.steamAccountsByBottle[bottle.name] ?? [], signedIn: signedIn)
                if note != accountNote { accountNote = note }
                try? await Task.sleep(for: .seconds(5))
            }
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
            if item.source == .steam, let owners = state.steamOwners(for: item) { steamAccountRow(owners) }
            if let note = accountNote {
                VStack(alignment: .leading, spacing: 6) {
                    row(L("Installed by"), note.installedBy.displayName)
                    if let other = note.otherAccount {
                        Label(String(format: note.steamRunning
                                     ? L("Steam is signed in as %@. That account may not have access to this game.")
                                     : L("Steam last signed in as %@. That account may not have access to this game."),
                                     other.displayName),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(HB.amber)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, Self.rowLabelWidth + 12)   // under the row's value
                    }
                }
            }
            if item.sizeOnDisk > 0 {
                row(L("Size on disk"), ByteCountFormatter.string(fromByteCount: item.sizeOnDisk, countStyle: .file))
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
                    Text(L("Starts through Steam for Mac.")).font(.callout).foregroundStyle(.secondary)
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
            } else if item.source == .epic || item.source == .gog {
                Button { state.install(item) } label: { primaryActionLabel(L("Install"), symbol: "arrow.down") }.buttonStyle(.borderedProminent).controlSize(.large).tint(HB.amber)
                    .disabled(state.busy)
                Text(String(format: L("Installs into %@."), state.defaultBottle?.name ?? L("your environment"))).font(.callout).foregroundStyle(.secondary)
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
                    }
                    Button(L("Install the Windows version instead")) { state.install(item) }
                        .buttonStyle(.link).font(.callout).disabled(state.busy || blocked)
                        .help(L("For when the Mac build lags behind or a mod needs the Windows one."))
                }
            } else if item.source == .steam, !steamHasManifest {
                // Owned, never installed here (highball#199): Steam's own dialog takes it from here.
                Button { state.install(item) } label: { primaryActionLabel(L("Install"), symbol: "arrow.down") }.buttonStyle(.borderedProminent).controlSize(.large).tint(HB.amber)
                    .disabled(state.busy)
                Text(L("Steam asks where to put it.")).font(.callout).foregroundStyle(.secondary)
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

    /// Whose Steam game this is, by profile name, and why Highball thinks so; the menu sets it.
    /// Shown only when Highball knows (SteamAccounts.Owners).
    private func steamAccountRow(_ owners: SteamAccounts.Owners) -> some View {
        let names = owners.accounts.compactMap { state.steamAccountName($0) }.sorted()
        let why: String = switch owners.reason {
        case .chosen: L("set by you")
        case .installed: L("installed it")
        case .added: L("signed in when it was added")
        }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L("Account")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Menu {
                ForEach(state.steamAccounts, id: \.id) { account in
                    Button(account.displayName) { state.setSteamOwners([account.id], for: item) }
                }
                Button(L("Every account here")) { state.setSteamOwners(Set(state.steamAccounts.map(\.id)), for: item) }
                Divider()
                Button(L("Let Highball guess")) { state.setSteamOwners(nil, for: item) }
            } label: {
                Text(names.joined(separator: ", ")).font(.callout)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .help(L("Whose Steam game this is. Highball goes by who installed it and who was signed in when it appeared; pick one to set it."))
            Text(why).font(.caption).foregroundStyle(.secondary)
        }
    }

    static let rowLabelWidth: CGFloat = 110

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: Self.rowLabelWidth, alignment: .leading)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }
}
