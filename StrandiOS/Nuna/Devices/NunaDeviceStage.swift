#if os(iOS)
import SwiftUI
import StrandDesign

/// The WHOOP MG strap product render used by Device Settings.
struct NunaStrapArt: View {
    var active: Bool
    @State private var on = true

    var body: some View {
        ZStack {
            Image("WHOOPBand")
                .resizable()
                .scaledToFit()
                .frame(width: 278, height: 320)
                .blur(radius: active ? 0 : 5)
                .opacity(active ? 1 : 0.7)
            Circle()
                .fill(active ? NunaPalette.charge : NunaPalette.alert)
                .frame(width: 7, height: 7)
                .opacity(active ? (on ? 1 : 0.2) : 1)
                .shadow(color: (active ? NunaPalette.charge : NunaPalette.alert).opacity(active ? (on ? 0.9 : 0) : 0.8), radius: 8)
                .offset(x: -54, y: -92)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: active)
        .task(id: active) {
            on = true
            guard active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                withAnimation(.easeInOut(duration: 0.25)) { on.toggle() }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The charging flow: drops of blue fall from the top of the column towards the battery bar, growing as they go and shrinking away as they reach it,
/// one after another, as the WHOOP app draws it. A small bolt stands at the top, where the charger is.
struct NunaChargeFlow: View {
    static let height: CGFloat = 124
    /// The circle with the bolt in it, and the length of the column it stands over.
    static let badge: CGFloat = 36
    private static let drops = 3
    private static let period = 2.4

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                for i in 0..<Self.drops {
                    // Each drop is a third of a cycle behind the one before it.
                    let phase = ((t / Self.period) + Double(i) / Double(Self.drops)).truncatingRemainder(dividingBy: 1)
                    let top = Self.badge + 6
                    let y = top + (size.height - top) * CGFloat(phase * phase * 0.35 + phase * 0.65)   // eases in, as a drop does
                    // Small at the top, largest in the middle, gone at the bar.
                    let r = 1.8 + 4.2 * CGFloat(sin(phase * .pi))
                    let alpha = min(1, phase * 6) * min(1, (1 - phase) * 3)
                    let rect = CGRect(x: size.width / 2 - r, y: y - r, width: r * 2, height: r * 2)
                    gc.fill(Path(ellipseIn: rect), with: .color(NunaPalette.effort.opacity(0.9 * alpha)))
                }
            }
        }
        .frame(width: Self.badge, height: Self.height)
        .overlay(alignment: .top) {
            // The charger: a bolt in a ring.
            ZStack {
                Circle().fill(NunaPalette.effort.opacity(0.14))
                Circle().stroke(NunaPalette.effort, lineWidth: 2)
                Image(systemName: "bolt.fill").font(.nuna(size: 18, weight: .bold)).foregroundStyle(NunaPalette.effort)
            }
            .frame(width: Self.badge, height: Self.badge)
        }
        .accessibilityHidden(true)
    }
}

/// A vertical battery: a thin track filled from the bottom, with the figure beside it. While the strap charges the drops of `NunaChargeFlow` run
/// into the top of the bar, and the figure carries a bolt.
struct NunaBatteryGauge: View {
    let pct: Double?
    let charging: Bool
    let model: String
    let estimate: String?

    /// Red at 10% or less, yellow up to 30%, green above. The WHOOP app showed yellow at 22% to 24% (the PHMN bar was green there): the exact limit is not
    /// published, so 30% is the nearest round figure that covers what was seen, and not an official one.
    private var tint: Color { (pct ?? 100) <= 10 ? NunaPalette.alert : ((pct ?? 100) <= 30 ? NunaPalette.warning : NunaPalette.charge) }
    private let barHeight: CGFloat = 250

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .trailing, spacing: 4) {
                if let pct {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(verbatim: "\(Int(pct.rounded()))").font(.nuna(size: 58, weight: .bold, design: NunaType.design)).foregroundStyle(NunaPalette.textPrimary)
                            .contentTransition(.numericText())
                        Text("%").font(.nuna(size: 24, weight: .bold)).foregroundStyle(NunaPalette.textPrimary)
                    }
                } else {
                    Text(verbatim: "–").font(.nuna(size: 58, weight: .bold, design: NunaType.design)).foregroundStyle(NunaPalette.textMuted)
                }
                Text(verbatim: model).font(.nuna(size: 12.5, weight: .heavy)).tracking(nunaTrackingLabel).textCase(.uppercase).foregroundStyle(NunaPalette.textSecondary)
                if let estimate {
                    Text(verbatim: estimate).font(.nuna(size: 12, weight: .semibold)).foregroundStyle(NunaPalette.textSecondary).textCase(nil)
                }
            }
            VStack(spacing: 4) {
                if charging { NunaChargeFlow().transition(.opacity) }
                ZStack(alignment: .bottom) {
                    Capsule().fill(NunaPalette.ink.opacity(0.10)).frame(width: 6, height: barHeight)
                    Capsule().fill(tint).frame(width: 6, height: max(6, barHeight * CGFloat((pct ?? 0) / 100)))
                        .animation(.easeOut(duration: 0.6), value: pct)
                }
            }
            .frame(width: NunaChargeFlow.badge)
            .animation(.easeInOut(duration: 0.3), value: charging)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: pct.map { "\(Int($0.rounded()))%" } ?? "–"))
        .accessibilityValue(charging ? Text("Charging") : Text(verbatim: ""))
    }
}

/// The picture at the heart of the Status tab: the strap, large and cut off by the screen edge, with its battery beside it when it is
/// connected. When it is not, the same picture, blurred, with a red light.
struct NunaDeviceStage: View {
    let connected: Bool
    let batteryPct: Double?
    let charging: Bool
    let model: String
    let estimate: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            NunaStrapArt(active: connected)
            if connected {
                NavigationLink(value: NunaDeviceRoute.battery) {
                    NunaBatteryGauge(pct: batteryPct, charging: charging, model: model, estimate: estimate)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 20).padding(.bottom, 14)
            }
        }
        .frame(height: 340)
    }
}
#endif
