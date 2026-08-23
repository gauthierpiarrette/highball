import AppKit
import HighballKit
import SwiftUI

@main
struct HighballApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Highball") {
            ContentView()
                .environment(state)
                .frame(minWidth: 780, minHeight: 520)
                .onAppear { state.refresh() }
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Works as a bare SwiftPM executable during development: give it a real UI presence.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var showCreate = false

    var body: some View {
        @Bindable var state = state
        Group {
            if state.needsOnboarding {
                OnboardingView()
            } else {
                NavigationSplitView {
                    List(selection: $state.selectedBottle) {
                        Section("Bottles") {
                            ForEach(state.bottles, id: \.name) { bottle in
                                Label(bottle.name, systemImage: "wineglass")
                                    .tag(bottle.name)
                            }
                        }
                        if let engine = state.engines.first {
                            Section("Engine") {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(engine.id).font(.caption).lineLimit(1)
                                    Text((try? engine.wineVersion()) ?? "")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230)
                    .toolbar {
                        Button { showCreate = true } label: { Label("New Bottle", systemImage: "plus") }
                    }
                } detail: {
                    if let name = state.selectedBottle,
                       let bottle = state.bottles.first(where: { $0.name == name }) {
                        BottleView(bottle: bottle)
                    } else {
                        ContentUnavailableView("No bottle selected", systemImage: "wineglass",
                                               description: Text("Create a bottle to install Steam and play."))
                    }
                }
            }
        }
        .sheet(isPresented: $showCreate) { CreateBottleSheet() }
        .sheet(isPresented: $state.showLog) { LogSheet() }
        .sheet(isPresented: $state.showGPTKLicense) { GPTKLicenseSheet() }
        .alert("Something went wrong", isPresented: .init(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK") { state.errorMessage = nil }
        } message: { Text(state.errorMessage ?? "") }
        .alert(item: $state.crashSuggestion) { s in
            Alert(title: Text("\(s.program) exited right away"),
                  message: Text("That usually means the graphics backend doesn't suit it. Try \(s.renderer.rawValue.uppercased())? The log is at \(s.logPath)."),
                  primaryButton: .default(Text("Use \(s.renderer.rawValue.uppercased())")) {
                      if let name = state.selectedBottle, var bottle = state.bottles.first(where: { $0.name == name }) {
                          bottle.settings.renderer = s.renderer
                          state.update(bottle)
                      }
                  },
                  secondaryButton: .cancel(Text("Keep current")))
        }
    }
}

struct CreateBottleSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var name = "play"
    @State private var installSteam = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New bottle").font(.title2.bold())
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 260)
            Toggle("Install Steam in it (recommended)", isOn: $installSteam)
            Text("A bottle is an isolated Windows environment. First boot takes about 90 seconds; the Steam install adds a download and a slow one-time client update.")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 380, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    dismiss()
                    state.createBottle(name: name, recipeID: installSteam ? "steam" : nil)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }
}

struct LogSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if state.busy { ProgressView().controlSize(.small) }
                Text(state.busy ? state.busyTitle : "Done").font(.headline)
                Spacer()
                Button(state.busy ? "Hide" : "Close") { dismiss() }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(state.logLines.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                }
                .onChange(of: state.logLines.count) { _, n in proxy.scrollTo(max(0, n - 1)) }
            }
            .frame(width: 620, height: 320)
            .background(.quaternary.opacity(0.4))
        }
        .padding(16)
    }
}
