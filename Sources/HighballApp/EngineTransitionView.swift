import HighballKit
import SwiftUI

/// Only mounted during a real engine move. No synthetic percentage or artificial delay.
struct EngineTransitionView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let change: AppState.EngineChange

    var body: some View {
        ZStack {
            HB.ground
            VStack(spacing: 24) {
                HighballMark(size: 108)
                VStack(spacing: 8) {
                    Text(change.title).font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text(change.bottleName).font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    Text(change.source).lineLimit(2)
                    Image(systemName: "arrow.right").foregroundStyle(HB.amber).accessibilityHidden(true)
                    Text(change.target).lineLimit(2)
                }
                .font(.caption.weight(.medium)).multilineTextAlignment(.center)
                .padding(16).frame(maxWidth: 430).hbPanel()
                VStack(spacing: 10) {
                    if let transfer = state.busyProgress,
                       let fraction = ActivityText.fraction(received: transfer.received, total: transfer.total) {
                        ProgressView(value: fraction).tint(HB.amber)
                        Text(ActivityText.transfer(received: transfer.received, total: transfer.total, rate: state.transferRate))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(state.stage.isEmpty ? L("Preparing your environment…") : state.stage)
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let expected = state.busyExpected {
                        Text(expected).font(.caption).foregroundStyle(.tertiary)
                    }
                }.frame(maxWidth: 360)
                HStack(spacing: 12) {
                    Button(L("Details")) { state.showLog = true }
                    if let stop = state.busyStop { Button(stop.label) { state.stopBusy() } }
                }.controlSize(.small)
            }
            .padding(32).frame(maxWidth: 530)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(change.title)
    }
}
