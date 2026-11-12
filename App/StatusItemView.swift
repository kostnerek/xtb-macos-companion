import SwiftUI
import XTBKit

@MainActor
final class BarModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var dailyChange: Double?
    @Published var hovered = false
    /// Height of the menu bar button; taller on screens with a camera notch.
    @Published var barHeight: CGFloat = 22
    /// Owner's setting: show the account value while the pointer is over the item.
    @Published var showEquityOnHover = true
    /// True when the numbers shown are not from a recent successful refresh.
    @Published var stale = true
}

/// The menu bar item: the total profit, centred. On hover it slides up and the account value
/// (unless switched off in the menu) and today's change appear under it. The item keeps the width
/// of its widest state, so the menu bar does not shift. The chart is only in the widget.
struct StatusItemView: View {
    @ObservedObject var model: BarModel

    private func color(_ amount: Double) -> Color {
        model.stale ? .secondary : (amount < 0 ? .red : .green)
    }

    var body: some View {
        HStack(spacing: 5) {
            if model.stale {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
            }
            if let snapshot = model.snapshot {
                ZStack(alignment: .trailing) {
                    lines(snapshot, expanded: true).hidden()
                    lines(snapshot, expanded: model.hovered)
                }
                .animation(.easeOut(duration: 0.18), value: model.hovered)
            } else {
                Text("XTB").font(.system(size: 12))
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 5)
        .frame(height: model.barHeight)
        .fixedSize()
    }

    private func lines(_ snapshot: Snapshot, expanded: Bool) -> some View {
        VStack(alignment: .trailing, spacing: -2) {
            Text(Money.signed(snapshot.profit, snapshot.currency))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color(snapshot.profit))
            if expanded {
                if model.showEquityOnHover {
                    Text(Money.plain(snapshot.equity, snapshot.currency))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(model.stale ? .secondary : .primary)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Text(model.dailyChange.map { "dziś " + Money.signed($0, snapshot.currency) } ?? "dziś —")
                    .font(.system(size: 9))
                    .foregroundStyle(color(model.dailyChange ?? 0))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}
