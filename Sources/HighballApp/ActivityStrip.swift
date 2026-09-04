import SwiftUI
import HighballKit

/// One place for everything that takes time (UX plan §3.3): the busy operation with its bytes,
/// stated range and elapsed time, a finished operation with its next step, and every running
/// game. Always at the bottom of the window, never modal, never a bare spinner. Details opens
/// the log sheet.
struct ActivityStrip: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.busy || state.doneState != nil || !state.runningSessions.isEmpty {
            VStack(spacing: 0) {
                Divider()
                VStack(spacing: 0) {
                    if state.busy {
                        busyRow
                    } else if let done = state.doneState {
                        doneRow(done)
                    }
                    ForEach(state.runningSessions) { session in
                        if state.busy || state.doneState != nil || session.id != state.runningSessions.first?.id { Divider().opacity(0.5) }
                        sessionRow(session)
                    }
                }
            }
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Rows

    private var busyRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.busyTitle).font(.callout.weight(.medium)).lineLimit(1)
                    if !state.stage.isEmpty || !state.stageHint.isEmpty {
                        Text([state.stage, state.stageHint].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    Text(measurements(at: ctx.date))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                if let stop = state.busyStop {
                    Button(stop.label) { state.stopBusy() }.controlSize(.small)
                }
                Button(L("Details")) { state.showLog = true }.controlSize(.small).buttonStyle(.link)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            // A determinate bar when bytes are known; nothing invented when they are not.
            if let p = state.busyProgress, let fraction = ActivityText.fraction(received: p.received, total: p.total) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.08))
                        Rectangle().fill(HB.amber).frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 3)
            }
        }
    }

    /// Bytes and rate when a download runs, elapsed always, the stated range when there is one.
    private func measurements(at now: Date) -> String {
        var parts: [String] = []
        if let p = state.busyProgress { parts.append(ActivityText.transfer(received: p.received, total: p.total, rate: state.transferRate)) }
        if let started = state.busyStartedAt {
            parts.append(ActivityText.minutes(since: started, now: now).map { String(format: L("%d min"), $0) } ?? L("just started"))
        }
        if let expected = state.busyExpected { parts.append(expected) }
        if state.busyProgress == nil, let last = state.lastOutputAt, now.timeIntervalSince(last) >= 90, state.stageHint.isEmpty {
            parts.append(L("quiet"))
        }
        return parts.joined(separator: " · ")
    }

    private func doneRow(_ done: AppState.DoneState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(HB.good)
            Text(done.title).font(.callout.weight(.medium)).lineLimit(1)
            Spacer(minLength: 12)
            if let cta = done.ctaTitle {
                Button(cta) { state.doneState = nil; done.cta?() }
                    .controlSize(.small).buttonStyle(.borderedProminent).tint(HB.amber)
            }
            Button(L("Details")) { state.showLog = true }.controlSize(.small).buttonStyle(.link)
            Button(L("Dismiss")) { state.doneState = nil }.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func sessionRow(_ session: GameSession) -> some View {
        HStack(spacing: 10) {
            Circle().fill(HB.good).frame(width: 8, height: 8).padding(.horizontal, 4)
            Text(String(format: L("%@ is running"), session.title)).font(.callout.weight(.medium)).lineLimit(1)
            Spacer(minLength: 12)
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                Text(ActivityText.minutes(since: session.started, now: ctx.date).map { String(format: L("%d min"), $0) } ?? L("just started"))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button(L("Stop")) { state.stopSession(session) }.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}
