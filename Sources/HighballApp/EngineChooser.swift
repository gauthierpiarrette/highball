import AppKit
import SwiftUI
import HighballKit

/// Used by both creation and environment settings. This never resolves a missing engine
/// through AppState.engine(for:), whose launch fallback would mislabel the assigned engine.
struct EngineSummary: View {
    let choice: EngineChoice?
    let isDefault: Bool
    let isCurrent: Bool

    var body: some View {
        if let choice {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: choice.displayName).font(.headline).textSelection(.enabled)
                if choice.displayName != choice.id {
                    Text(verbatim: choice.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                EngineChoiceDetails(choice: choice, isDefault: isDefault, isCurrent: isCurrent)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(L("No engine is installed yet. Reinstall Highball, or restart it to finish setup."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct EngineChoiceDetails: View {
    let choice: EngineChoice
    let isDefault: Bool
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if choice.arch != nil {
                Text(choice.arch == "arm64" ? L("Native Apple silicon") : L("Runs through Rosetta"))
                    .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { EngineChoiceBadges(choice: choice, isDefault: isDefault, isCurrent: isCurrent) }
                VStack(alignment: .leading, spacing: 4) { EngineChoiceBadges(choice: choice, isDefault: isDefault, isCurrent: isCurrent) }
            }
            if !choice.supported, let floor = choice.minMacOS {
                Text(String(format: L("This engine requires macOS %@ or later."), floor)).foregroundStyle(HB.amber)
            }
        }.font(.caption)
    }
}

private struct EngineChoiceBadges: View {
    let choice: EngineChoice
    let isDefault: Bool
    let isCurrent: Bool

    var body: some View {
        Text(choice.missing ? L("Missing") : choice.installed ? L("Installed") : L("Download"))
        if !choice.installed, !choice.missing, choice.downloadBytes > 0 {
            Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(choice.downloadBytes), countStyle: .file))
        }
        if isDefault { Text(L("Default")) }
        if isCurrent { Text(L("Current")) }
        if choice.custom { Text(L("Custom")) }
        if choice.channel == EngineChannels.preview { Text(L("Preview")) }
        if choice.channel == EngineChannels.beta { Text(L("Beta")) }
    }
}

/// The chooser owns a draft. Highlighting a row never writes
/// environment settings. Review and separate creation remain in this same sheet, so they
/// work from both the main window and Settings without dismiss/present races.
struct EngineChooser: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let currentID: String?
    let bottleName: String?
    let onSelect: (String) -> Void
    @State private var draftID: String
    @AppStorage(EngineStore.showOlderRevisionsKey) private var showOlderRevisions = false
    @State private var review: AppState.EngineTransition?
    @State private var newEnvironmentID: String?
    @State private var newEnvironmentName = ""

    init(selectionID: String, currentID: String? = nil, bottleName: String? = nil, onSelect: @escaping (String) -> Void) {
        self.currentID = currentID
        self.bottleName = bottleName
        self.onSelect = onSelect
        _draftID = State(initialValue: selectionID)
    }

    var body: some View {
        if let review {
            EngineTransitionSheet(transition: review)
        } else if let newEnvironmentID {
            CreateBottleSheet(engineID: newEnvironmentID, suggestedName: newEnvironmentName, sourceEnvironment: bottleName)
        } else {
            let choices = state.engineChoices(currentID: currentID, selectedID: draftID, allRevisions: showOlderRevisions)
            let compatible = choices.filter { !$0.requiresNewEnvironment }
            let separate = choices.filter(\.requiresNewEnvironment)
            let selected = choices.first { $0.id == draftID }
            VStack(alignment: .leading, spacing: 16) {
                Text(L("Choose an engine")).font(.title2.bold())
                Text(bottleName == nil ? L("Choose what this environment will run with.") : L("Changing the engine affects every program in this environment. You’ll review the switch before anything changes."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        EngineChoiceList(choices: compatible, selection: $draftID, defaultID: state.defaultEngine?.id, currentID: currentID)
                        if !compatible.contains(where: { $0.selectable && $0.id != (currentID ?? draftID) }) {
                            Text(L("No other compatible engines are available for this Mac."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !separate.isEmpty {
                            Text(L("Requires a new environment")).font(.headline)
                            Text(L("Moving between Rosetta and native Apple silicon requires a new environment."))
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(separate) { choice in
                                OtherArchitectureEngineRow(choice: choice, busy: state.busy) {
                                    newEnvironmentName = BottleStore.freeName(
                                        BottleStore.safeName(fromTitle: (bottleName ?? "play") + " - " + choice.displayName),
                                        taken: Set(state.bottles.map(\.name) + state.damagedBottles.map(\.name)))
                                    newEnvironmentID = choice.id
                                }
                            }
                        }
                        Toggle(L("Show older engine revisions"), isOn: $showOlderRevisions)
                    }.padding(2)
                }
                .frame(maxHeight: 390)
                EngineChooserActivity()
                HStack {
                    Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(bottleName == nil ? L("Use engine") : L("Review switch…")) {
                        guard let selected, selected.selectable, !selected.requiresNewEnvironment else { return }
                        if let bottleName {
                            review = AppState.EngineTransition(bottleName: bottleName, targetID: selected.id)
                        } else {
                            onSelect(selected.id)
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.busy || selected?.selectable != true || selected?.requiresNewEnvironment == true || (bottleName != nil && draftID == currentID))
                }
            }
            .padding(22)
            .frame(width: 560)
        }
    }
}

private struct EngineChoiceList: View {
    let choices: [EngineChoice]
    @Binding var selection: String
    let defaultID: String?
    let currentID: String?

    var body: some View {
        VStack(spacing: 8) {
            ForEach(choices) { choice in
                EngineChoiceRow(choice: choice, selected: choice.id == selection,
                                isDefault: choice.id == defaultID, isCurrent: choice.id == currentID) {
                    selection = choice.id
                    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                         userInfo: [.announcement: String(format: L("Selected engine: %@"), choice.displayName), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
            }
        }
    }
}

private struct EngineChoiceRow: View {
    let choice: EngineChoice
    let selected: Bool
    let isDefault: Bool
    let isCurrent: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").padding(.top, 2).accessibilityHidden(true)
                EngineSummary(choice: choice, isDefault: isDefault, isCurrent: isCurrent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? HB.amber.opacity(0.12) : HB.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? HB.amber : HB.cardStroke))
        }
        .buttonStyle(.plain)
        .disabled(!choice.selectable)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct OtherArchitectureEngineRow: View {
    let choice: EngineChoice
    let busy: Bool
    let create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EngineSummary(choice: choice, isDefault: false, isCurrent: false)
            Button(L("New environment…"), action: create).disabled(busy || !choice.selectable)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(HB.card))
    }
}

struct EnvironmentEngineSection: View {
    @Environment(AppState.self) private var state
    let engineID: String
    let bottleName: String
    @State private var showChooser = false

    var body: some View {
        let choices = state.engineChoices(currentID: engineID, selectedID: engineID)
        let current = choices.first { $0.id == engineID }
        Section(L("Engine")) {
            EngineSummary(choice: current, isDefault: engineID == state.defaultEngine?.id, isCurrent: true)
            if choices.contains(where: { $0.id != engineID && $0.selectable }) {
                Button(L("Change…")) { showChooser = true }
            } else {
                Text(L("No other engines are available for this Mac.")).font(.caption).foregroundStyle(.secondary)
                Button(L("Choose an engine…")) { showChooser = true }
            }
            if current?.installed == false {
                Button(L("Install again")) { state.reinstallEngine(engineID) }.disabled(state.busy || current?.supported != true)
            }
            Text(L("Changing the engine affects every program in this environment. You’ll review the switch before anything changes."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showChooser) {
            EngineChooser(selectionID: engineID, currentID: engineID, bottleName: bottleName, onSelect: { _ in })
        }
    }
}

/// Keep ongoing work visible while the chooser is open for inspection.
private struct EngineChooserActivity: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.busy {
            HStack {
                ProgressView().controlSize(.small)
                Text(L(state.busyTitle)).font(.caption)
                Spacer()
                if let stop = state.busyStop { Button(stop.label) { state.stopBusy() } }
            }
        }
    }
}
