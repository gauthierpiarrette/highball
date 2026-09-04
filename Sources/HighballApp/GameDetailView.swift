import SwiftUI
import HighballKit

/// A game's page (UX plan §3.5): a verdict written as a sentence, Play as the only button, an
/// honest list of what Play will do, and every identifier behind one Advanced triangle.
struct GameDetailView: View {
    @Environment(AppState.self) private var state
    let item: LibraryItem
    @State private var showBottleSettings = false
    @State private var showWhy = false
    @State private var showAdvanced = false

    private var entry: GameDBEntry? { item.steamAppID.flatMap { state.gameDB[$0] } }
    private var bottle: Bottle? { item.bottleName.flatMap { name in state.bottles.first { $0.name == name } } }
    private var blocked: Bool { entry?.isBlocked == true }
    private var fixRecipe: HighballKit.Recipe? { state.fixRecipe(for: item) }
    private var fixApplied: Bool {
        guard let fixRecipe, let bottle else { return false }
        return bottle.settings.recipes.contains(fixRecipe.id)
    }
    private var running: GameSession? {
        if let appid = item.steamAppID, let s = state.session(forAppID: appid) { return s }
        return state.runningSessions.first { $0.title == item.title && $0.bottleName == item.bottleName }
    }
    private var verdict: GamePageCopy.Verdict { GamePageCopy.verdict(entry, myChip: state.machineChip) }
    private var willDo: [GamePageCopy.WillDo] {
        GamePageCopy.willDo(entry, recipe: fixRecipe, applied: fixApplied, bottleRenderer: bottle?.settings.renderer ?? .dxvk,
                            explicit: bottle?.settings.rendererExplicit ?? false)
    }
    private var engineName: String? { bottle.flatMap { state.engine(for: $0) }?.displayName }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                verdictBlock
                playRow
                if item.installed, !blocked { willDoCard }
                advanced
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BottleBackdrop())
        .navigationTitle(item.title)
        .sheet(isPresented: $showBottleSettings) {
            if let bottle { BottleSettingsSheet(bottle: bottle) }
        }
    }

    // MARK: Pieces

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .aspectRatio(460 / 215, contentMode: .fit)
                .frame(maxWidth: 640)
                .overlay(
                    AsyncImage(url: item.artworkWide ?? item.artworkTall) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            ZStack {
                                LinearGradient(colors: [HB.card, HB.ground], startPoint: .top, endPoint: .bottom)
                                Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.quaternary)
                            }
                        }
                    }
                )
                .clipped()
            LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .bottom, endPoint: .center)
                .frame(maxWidth: 640)
            Text(item.title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white).shadow(radius: 4)
                .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HB.cardStroke))
    }

    private var verdictColor: Color {
        switch entry?.status {
        case "verified-local": return HB.good
        case "blocked-anticheat": return HB.bad
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

    private var playRow: some View {
        HStack(spacing: 14) {
            if let running {
                Button(L("Stop")) { state.stopSession(running) }.buttonStyle(.bordered).controlSize(.large)
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    Text(ActivityText.minutes(since: running.started, now: ctx.date)
                            .map { String(format: L("Running for %d min"), $0) } ?? L("Running"))
                        .font(.callout).foregroundStyle(HB.good)
                }
            } else if item.installed {
                Button { state.play(item) } label: {
                    Label(L("Play"), systemImage: "play.fill").frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(HB.amber)
                .disabled(state.busy || blocked)
                Text(blocked ? L("Its anti-cheat does not run on macOS.") : L("Highball will ask how it went when you finish."))
                    .font(.callout).foregroundStyle(.secondary)
            } else if item.source == .epic {
                Button(L("Install")) { state.install(item) }.buttonStyle(.borderedProminent).controlSize(.large).tint(HB.amber)
                    .disabled(state.busy)
                Text(L("Installs into your Highball environment.")).font(.callout).foregroundStyle(.secondary)
            } else {
                Text(L("Not installed in any environment.")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var willDoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HB.eyebrow(L("When you press Play, Highball will"))
            ForEach(Array(willDo.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: line.done ? "checkmark" : (line.cost == nil ? "checkmark" : "hourglass"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(line.cost == nil || line.done ? HB.good : HB.amber)
                        .frame(width: 14)
                    Text(line.text).font(.callout)
                    if let cost = line.cost {
                        Text(cost).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 6) {
                Text(entry == nil ? L("No row in the compatibility database yet.") : L("From the open compatibility database."))
                    .font(.caption).foregroundStyle(.secondary)
                if entry != nil {
                    Button(L("Why these settings?")) { showWhy.toggle() }
                        .buttonStyle(.link).font(.caption)
                        .popover(isPresented: $showWhy, arrowEdge: .bottom) { whyPopover }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(HB.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(HB.cardStroke))
    }

    /// The explanation, and the way out: the environment's own settings are one click away.
    private var whyPopover: some View {
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
            Text(L("To play with the environment's own graphics mode instead, change it under Advanced below; Highball then leaves it alone for every game in that environment."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 420)
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 14) {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    if let bottle {
                        HStack(alignment: .top, spacing: 12) {
                            Text(L("Graphics mode")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading).padding(.top, 4)
                            GraphicsModePicker(bottle: bottle)
                        }
                        row(L("Engine"), (state.engine(for: bottle)?.displayName).map { "\($0) · \(bottle.settings.engineID)" } ?? bottle.settings.engineID)
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(L("Environment")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            Text(bottle.name).font(.callout)
                            Button(L("Environment settings…")) { showBottleSettings = true }.controlSize(.small)
                        }
                        if !item.otherBottles.isEmpty {
                            row(L("Also installed in"), item.otherBottles.joined(separator: ", "))
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(L("Files")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            Button(L("Show the Windows drive")) { NSWorkspace.shared.open(bottle.driveC) }.controlSize(.small)
                            if PlayLink.target(for: item) != nil {
                                Button(L("Make a Mac app…")) { state.makeMacApp(for: item) }.controlSize(.small)
                                    .help(L("A small app in ~/Applications/Highball that starts this game without opening Highball first."))
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
                HStack(spacing: 8) {
                    Text(L("Advanced")).font(.callout.weight(.medium))
                    Text(L("graphics mode · engine · environment · files")).font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                row(L("Source"), item.source == .steam ? "Steam" : item.source == .epic ? "Epic Games" : L("Windows program"))
                if item.sizeOnDisk > 0 {
                    row(L("Size on disk"), ByteCountFormatter.string(fromByteCount: item.sizeOnDisk, countStyle: .file))
                }
                if let played = item.lastPlayed {
                    row(L("Last played"), played.formatted(date: .abbreviated, time: .shortened))
                }
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
