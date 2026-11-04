import SwiftUI
import HighballKit

/// The Add games flow stays in the library window; installs still use the activity strip.
struct AddGamesView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    private var unavailable: Bool { state.busy || state.bottles.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Where are your games?")).font(.title2.bold())
                    Text(L("Choose a store or a Windows program you already have."))
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                    sourceCard("Steam", symbol: "gamecontroller.fill",
                               description: L("Install games through the Windows Steam client."),
                               action: state.defaultBottle.map(state.steamInstalled) == true ? L("Open Steam") : L("Install Steam")) {
                        state.installSteam()
                    }
                    sourceCard("Epic Games", symbol: "e.square.fill",
                               description: L("Connect your Epic account to see and download your games."),
                               action: state.epicSignedIn ? L("Epic account connected") : L("Connect Epic account…"),
                               connected: state.epicSignedIn) {
                        state.showEpicSignIn = true
                    }
                    sourceCard("GOG", symbol: "g.circle.fill",
                               description: L("Connect your GOG account to see and download your games."),
                               action: state.gogSignedIn ? L("GOG account connected") : L("Connect GOG account…"),
                               connected: state.gogSignedIn, manage: { state.showGOGSignIn = true }) {
                        state.showGOGSignIn = true
                    }
                    sourceCard(L("A Windows program I have…"), symbol: "app.dashed",
                               description: L("Choose an .exe, .msi or .bat file, or drop it on this window."),
                               action: L("Choose a file…")) {
                        state.chooseProgramToRun()
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HB.eyebrow(L("Launchers"))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 170), spacing: 12)], spacing: 12) {
                        // Steam and GOG have their own cards above; GOG Galaxy's own client stays blocked
                        // (its sign-in window draws black), and Connect GOG does its jobs instead.
                        ForEach(BottleView.launcherMeta.filter { $0.id != "steam" && $0.id != "gog-galaxy" }, id: \.id) { meta in
                            if let recipe = AppState.recipe(meta.id) {
                                LauncherTile(title: meta.short, symbol: meta.symbol,
                                             installed: state.launcherInstalled(meta.id), busy: unavailable,
                                             blockedReason: recipe.blocked?.reason, flakyReason: recipe.flaky?.reason) {
                                    state.openOrInstallLauncher(meta.id, short: meta.short)
                                }
                            }
                        }
                    }
                    Text(L("Kernel anti-cheat titles (Valorant, Fortnite, Destiny 2…) can’t work through Wine — check the compatibility database before big downloads."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(BottleBackdrop())
        .background { PageCancelShortcut { dismiss() } }
        .navigationTitle(L("Add games"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func sourceCard(_ title: String, symbol: String, description: String,
                            action: String, connected: Bool = false, manage: (() -> Void)? = nil,
                            perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.title).foregroundStyle(HB.amber)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(description).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if connected {
                HStack {
                    Label(action, systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(HB.good)
                    // The way back to a connected account: switching accounts, or disconnecting.
                    if let manage {
                        Spacer()
                        Button(L("Manage…"), action: manage).buttonStyle(.plain).font(.callout).foregroundStyle(HB.amber)
                    }
                }
            } else {
                Button(action, action: perform).buttonStyle(.bordered).disabled(unavailable)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(HB.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HB.cardStroke))
    }
}

/// Navigation pages need an explicit Escape shortcut even when no control has keyboard focus.
struct PageCancelShortcut: View {
    let action: () -> Void

    var body: some View {
        Button(L("Done"), action: action)
            .keyboardShortcut(.cancelAction)
            .hidden()
            .accessibilityHidden(true)
    }
}
