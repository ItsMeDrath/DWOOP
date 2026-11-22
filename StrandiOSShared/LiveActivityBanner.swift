import WidgetKit
import SwiftUI
import StrandDesign
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import ActivityKit
#endif

// The "Banner" design of the workout Live Activity: one dark card. At the top the heart (a muted heart, the heart rate large, "bpm" small) on the left
// and the session clock in a blue pill on the right; under them the heart-rate bar, five segments from Zone 1 to Zone 5, filled in white as far as the
// heart rate has climbed with a white marker at it, and the name of the zone under its segment; at the foot three columns split by hairlines: a figure
// with its name, the WHOOP wordmark, and a second figure. Every colour is fixed, so it reads the same on any wallpaper and in either appearance.

enum NOOPBannerPalette {
    static let top = Color(hex: "#1B242B")
    static let bottom = Color(hex: "#11181D")
    static let ink = Color.white
    static let paused = Color(hex: "#F5B02E")
    static let pausedPill = Color(hex: "#3A2B0A")
    static let muted = Color(hex: "#9AA3AB")
    static let track = Color(hex: "#5A6168")
    static let divider = Color(hex: "#3A4249")
    static let soft = Color(hex: "#DDE3E8")
    /// The clock's pill: a deep blue with a brighter blue stopwatch.
    static let pill = Color(hex: "#0B2F47")
    static let pillInk = Color(hex: "#1D8FEA")

    /// The figures: DIN Pro Bold, as the reference (the app's WHP face; D-DIN-PRO and then the system's condensed bold stand in if a file is missing).
    static func din(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        #if canImport(UIKit)
        for name in ["DINPro-Bold", "D-DIN-PRO-Bold"] where UIFont(name: name, size: size) != nil { return .custom(name, size: size) }
        #endif
        return .system(size: size, weight: .bold, design: .default).width(.condensed)
    }

    /// The words ("bpm", the units, the captions): Proxima Nova, as the reference.
    static func words(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .heavy, .black, .bold: name = "ProximaNova-Extrabld"
        case .semibold, .medium: name = "ProximaNova-Semibold"
        default: name = "ProximaNova-Regular"
        }
        #if canImport(UIKit)
        if UIFont(name: name, size: size) != nil { return .custom(name, size: size) }
        #endif
        return .system(size: size, weight: weight, design: .default)
    }

    /// The zones, easy to hard: slate, blue, teal, bronze, rust.
    static func zone(_ n: Int) -> Color {
        [Color(hex: "#6C7B88"), Color(hex: "#4FA3D9"), Color(hex: "#3FA391"), Color(hex: "#C08A4E"), Color(hex: "#D2603F")][min(max(n, 1), 5) - 1]
    }
}

struct NOOPBannerLockScreen: View {
    let state: NOOPActivityAttributes.ContentState

    private var paused: Bool { state.pausedAt != nil }
    /// The zone the heart rate is in, 1 to 5 (below Zone 1 reads as Zone 1).
    private var zone: Int { min(max(state.heartRateZone ?? 1, 1), 5) }

    /// A Lock Screen Live Activity has about 160 pt; this card takes about 153, laid out to the reference's proportions.
    var body: some View {
        VStack(spacing: 0) {
            topRow
            zoneBar.padding(.top, 11)
            columns.padding(.top, 9)
        }
        .padding(.horizontal, 20).padding(.vertical, 15)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [NOOPBannerPalette.top, NOOPBannerPalette.bottom], startPoint: .top, endPoint: .bottom))
    }

    // MARK: Top row

    private var topRow: some View {
        HStack(alignment: .center, spacing: 0) {
            heartRate
            Spacer(minLength: 8)
            clockPill
        }
        .frame(height: 38)
    }

    /// A muted heart, the number, "bpm" small beside it on the number's baseline.
    private var heartRate: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: "heart.fill").font(.system(size: 17, weight: .heavy)).foregroundStyle(NOOPBannerPalette.muted)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 5 }
            Text(verbatim: state.bpm.map(String.init) ?? "–").font(NOOPBannerPalette.din(32)).monospacedDigit()
                .foregroundStyle(NOOPBannerPalette.ink).lineLimit(1).minimumScaleFactor(0.6)
            Text("bpm").font(NOOPBannerPalette.words(19)).foregroundStyle(NOOPBannerPalette.muted).textCase(nil).padding(.leading, 1)
                .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] }
        }
        .fixedSize()
    }

    /// The session clock in a pill: a stopwatch and the time, m:ss until the first hour and h:mm:ss after it. Paused, the pill turns amber, shows a
    /// pause mark and the clock stands still.
    private var clockPill: some View {
        let tint = paused ? NOOPBannerPalette.paused : NOOPBannerPalette.pillInk
        let elapsed = state.activityStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        return HStack(spacing: 8) {
            Image(systemName: paused ? "pause.fill" : "stopwatch").font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
            Group {
                if let start = state.activityStartedAt {
                    Text(timerInterval: start...start.addingTimeInterval(86_400), pauseTime: state.pausedAt, countsDown: false)
                } else {
                    Text(verbatim: "–")
                }
            }
            .font(NOOPBannerPalette.din(24)).monospacedDigit()
            .foregroundStyle(paused ? NOOPBannerPalette.paused : NOOPBannerPalette.ink)
            .lineLimit(1)
            // A timer text takes all the width it is offered; give it its own.
            .frame(width: elapsed >= 3600 ? 86 : (elapsed >= 600 ? 63 : 45), alignment: .leading)
        }
        .padding(.horizontal, 13).frame(height: 38)
        .background(paused ? NOOPBannerPalette.pausedPill : NOOPBannerPalette.pill, in: Capsule())
    }

    // MARK: Zone bar

    /// Five segments, Zone 1 to Zone 5. The segments up to the heart rate's own are white, the marker sits in its segment, and the name of the zone
    /// stands under the start of that segment.
    private var zoneBar: some View {
        GeometryReader { geo in
            let gap: CGFloat = 1.5
            let seg = (geo.size.width - gap * 4) / 5
            let level = min(max(state.zoneLevel ?? 0, 0), 1) * 5
            let index = min(Int(level), 4)
            let knobX = CGFloat(index) * (seg + gap) + CGFloat(level - Double(index)) * seg
            let live = state.bpm != nil
            VStack(alignment: .leading, spacing: 3) {
                ZStack(alignment: .leading) {
                    HStack(spacing: gap) {
                        ForEach(0..<5, id: \.self) { i in
                            Capsule().fill(live && i <= index ? Color.white : NOOPBannerPalette.track).frame(width: seg, height: 4)
                        }
                    }
                    if live {
                        Circle().fill(Color.white).frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(NOOPBannerPalette.bottom, lineWidth: 1.5))
                            .offset(x: min(max(knobX - 6, 0), geo.size.width - 12))
                    }
                }
                .frame(height: 12)
                Text(verbatim: live ? "ZONE \(zone)" : "ZONE –")
                    .font(NOOPBannerPalette.words(10.5, .heavy)).tracking(1.4)
                    .foregroundStyle(NOOPBannerPalette.ink).lineLimit(1)
                    .padding(.leading, CGFloat(live ? index : 0) * (seg + gap) + 6)
            }
        }
        .frame(height: 28)
    }

    // MARK: Figures

    private struct Figure: Identifiable {
        let id: String
        let label: LocalizedStringKey
        let value: String
        var unit = ""
    }

    private var onFoot: Bool { state.activityName.map(ActivitySport.countsSteps) ?? false }
    private var isCycling: Bool { state.activityName == "Cycling" }
    private var isRoute: Bool { state.activityName.map { ActivitySport.isRoute($0) } == true || state.distance != nil || state.pace != nil }

    /// "3.42 km" -> ("3.42", "km"); a value with no unit comes back whole.
    private static func split(_ s: String?) -> (String, String) {
        guard let s, !s.isEmpty else { return ("–", "") }
        guard let i = s.lastIndex(of: " ") else { return (s, "") }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }

    /// Two figures: distance and pace (speed on a bike) with a route; otherwise steps or calories, and calories or the session's Effort.
    private var figureList: [Figure] {
        let calories = Figure(id: "calories", label: "CALORIES", value: state.calories.map(String.init) ?? "–", unit: state.calories == nil ? "" : String(localized: "kcal"))
        if isRoute {
            let d = Self.split(state.distance)
            let p = Self.split(isCycling ? state.speed : state.pace)
            return [Figure(id: "distance", label: "DISTANCE", value: d.0, unit: d.1),
                    Figure(id: "pace", label: isCycling ? "SPEED" : "PACE", value: p.0, unit: p.1)]
        }
        let effort = Figure(id: "effort", label: "STRAIN", value: state.effortLabel ?? state.effort.map(String.init) ?? "–")
        if onFoot, let steps = state.steps { return [Figure(id: "steps", label: "STEPS", value: String(steps)), calories] }
        return [calories, effort]
    }

    /// Three equal columns split by hairlines: the first figure, the wordmark, the second figure.
    private var columns: some View {
        let items = figureList
        return HStack(spacing: 0) {
            figure(items[0])
            divider
            NOOPBannerWhoopWordmark(color: NOOPBannerPalette.muted).frame(maxWidth: .infinity)
            divider
            figure(items.count > 1 ? items[1] : items[0])
        }
        .frame(height: 37)
    }

    private var divider: some View { Rectangle().fill(NOOPBannerPalette.divider).frame(width: 1, height: 35) }

    private func figure(_ item: Figure) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: item.value).font(NOOPBannerPalette.din(18)).monospacedDigit()
                    .foregroundStyle(NOOPBannerPalette.ink).lineLimit(1).minimumScaleFactor(0.6)
                if !item.unit.isEmpty { Text(verbatim: item.unit).font(NOOPBannerPalette.words(13)).foregroundStyle(NOOPBannerPalette.muted).textCase(nil) }
            }
            Text(item.label).font(NOOPBannerPalette.words(11, .semibold)).tracking(1.3).foregroundStyle(NOOPBannerPalette.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

extension NOOPActivityAttributes.ContentState {
    /// A running session with made-up figures, to show the Banner design in Settings.
    static func bannerDemo(now: Date = Date()) -> NOOPActivityAttributes.ContentState {
        NOOPActivityAttributes.ContentState(
            bpm: 138, recovery: nil, bonded: true, batteryPct: 68, effort: 4,
            heartRateZone: 3, activityName: "Running", activityStartedAt: now.addingTimeInterval(-(14 * 60 + 27)),
            averageBPM: 131, peakBPM: 152, distance: "2.31 km", pace: "6:12 /km", calories: 186,
            zonePosition: 0.56, effortLabel: "4.1", design: "banner", zoneLevel: 0.51)
    }
}


private struct NOOPBannerWhoopWordmark: View {
    var color: Color = .white
    var body: some View {
        GeometryReader { geometry in
            Self.drawingPath(in: CGRect(origin: .zero, size: geometry.size)).fill(color, style: FillStyle(eoFill: true))
        }.accessibilityLabel("WHOOP")
    }
    nonisolated static func drawingPath(in rect: CGRect) -> Path {
        let scale = min(rect.width / 236, rect.height / 40)
        return Path { path in
                path.move(to: CGPoint(x: 68.25, y: 0.05))
                path.addLine(to: CGPoint(x: 63.37, y: 0.05))
                path.addLine(to: CGPoint(x: 63.37, y: 39.99))
                path.addLine(to: CGPoint(x: 68.25, y: 39.99))
                path.addLine(to: CGPoint(x: 68.25, y: 0.05))
                path.closeSubpath()
                path.move(to: CGPoint(x: 87.14, y: 17.59))
                path.addLine(to: CGPoint(x: 73.13, y: 17.59))
                path.addLine(to: CGPoint(x: 73.13, y: 22.47))
                path.addLine(to: CGPoint(x: 87.14, y: 22.47))
                path.addLine(to: CGPoint(x: 87.14, y: 17.59))
                path.closeSubpath()
                path.move(to: CGPoint(x: 96.89, y: 0.05))
                path.addLine(to: CGPoint(x: 92.01, y: 0.05))
                path.addLine(to: CGPoint(x: 92.01, y: 39.99))
                path.addLine(to: CGPoint(x: 96.89, y: 39.99))
                path.addLine(to: CGPoint(x: 96.89, y: 0.05))
                path.closeSubpath()
                path.move(to: CGPoint(x: 205.3, y: 40.0))
                path.addLine(to: CGPoint(x: 210.18, y: 40.0))
                path.addLine(to: CGPoint(x: 210.18, y: 0.05))
                path.addLine(to: CGPoint(x: 205.3, y: 0.05))
                path.addLine(to: CGPoint(x: 205.3, y: 40.0))
                path.closeSubpath()
                path.move(to: CGPoint(x: 221.58, y: 0.05))
                path.addLine(to: CGPoint(x: 215.06, y: 0.05))
                path.addLine(to: CGPoint(x: 215.06, y: 4.79))
                path.addLine(to: CGPoint(x: 221.58, y: 4.79))
                path.addCurve(to: CGPoint(x: 230.46, y: 13.67), control1: CGPoint(x: 226.47, y: 4.79), control2: CGPoint(x: 230.46, y: 8.77))
                path.addCurve(to: CGPoint(x: 221.58, y: 22.56), control1: CGPoint(x: 230.46, y: 18.57), control2: CGPoint(x: 226.47, y: 22.56))
                path.addLine(to: CGPoint(x: 215.06, y: 22.56))
                path.addLine(to: CGPoint(x: 215.06, y: 27.3))
                path.addLine(to: CGPoint(x: 221.58, y: 27.3))
                path.addCurve(to: CGPoint(x: 235.2, y: 13.68), control1: CGPoint(x: 229.08, y: 27.3), control2: CGPoint(x: 235.2, y: 21.19))
                path.addCurve(to: CGPoint(x: 221.58, y: 0.05), control1: CGPoint(x: 235.2, y: 6.16), control2: CGPoint(x: 229.08, y: 0.05))
                path.closeSubpath()
                path.move(to: CGPoint(x: 126.53, y: 0.05))
                path.addCurve(to: CGPoint(x: 106.56, y: 20.02), control1: CGPoint(x: 115.52, y: 0.05), control2: CGPoint(x: 106.56, y: 9.01))
                path.addCurve(to: CGPoint(x: 126.53, y: 39.99), control1: CGPoint(x: 106.56, y: 31.04), control2: CGPoint(x: 115.52, y: 39.99))
                path.addCurve(to: CGPoint(x: 146.5, y: 20.02), control1: CGPoint(x: 137.54, y: 39.99), control2: CGPoint(x: 146.5, y: 31.03))
                path.addCurve(to: CGPoint(x: 126.53, y: 0.05), control1: CGPoint(x: 146.5, y: 9.01), control2: CGPoint(x: 137.54, y: 0.05))
                path.closeSubpath()
                path.move(to: CGPoint(x: 126.53, y: 35.28))
                path.addCurve(to: CGPoint(x: 111.27, y: 20.02), control1: CGPoint(x: 118.11, y: 35.28), control2: CGPoint(x: 111.27, y: 28.44))
                path.addCurve(to: CGPoint(x: 126.53, y: 4.76), control1: CGPoint(x: 111.27, y: 11.6), control2: CGPoint(x: 118.11, y: 4.76))
                path.addCurve(to: CGPoint(x: 141.79, y: 20.02), control1: CGPoint(x: 134.95, y: 4.76), control2: CGPoint(x: 141.79, y: 11.6))
                path.addCurve(to: CGPoint(x: 126.53, y: 35.28), control1: CGPoint(x: 141.79, y: 28.44), control2: CGPoint(x: 134.94, y: 35.28))
                path.closeSubpath()
                path.move(to: CGPoint(x: 175.03, y: 0.05))
                path.addCurve(to: CGPoint(x: 155.07, y: 20.02), control1: CGPoint(x: 164.02, y: 0.05), control2: CGPoint(x: 155.07, y: 9.01))
                path.addCurve(to: CGPoint(x: 175.03, y: 39.99), control1: CGPoint(x: 155.07, y: 31.04), control2: CGPoint(x: 164.03, y: 39.99))
                path.addCurve(to: CGPoint(x: 195.01, y: 20.02), control1: CGPoint(x: 186.04, y: 39.99), control2: CGPoint(x: 195.01, y: 31.03))
                path.addCurve(to: CGPoint(x: 175.03, y: 0.05), control1: CGPoint(x: 195.01, y: 9.01), control2: CGPoint(x: 186.04, y: 0.05))
                path.closeSubpath()
                path.move(to: CGPoint(x: 175.03, y: 35.28))
                path.addCurve(to: CGPoint(x: 159.78, y: 20.02), control1: CGPoint(x: 166.62, y: 35.28), control2: CGPoint(x: 159.78, y: 28.44))
                path.addCurve(to: CGPoint(x: 175.03, y: 4.76), control1: CGPoint(x: 159.78, y: 11.6), control2: CGPoint(x: 166.62, y: 4.76))
                path.addCurve(to: CGPoint(x: 190.29, y: 20.02), control1: CGPoint(x: 183.45, y: 4.76), control2: CGPoint(x: 190.29, y: 11.6))
                path.addCurve(to: CGPoint(x: 175.03, y: 35.28), control1: CGPoint(x: 190.29, y: 28.44), control2: CGPoint(x: 183.45, y: 35.28))
                path.closeSubpath()
                path.move(to: CGPoint(x: 39.63, y: 32.22))
                path.addLine(to: CGPoint(x: 34.44, y: 15.14))
                path.addLine(to: CGPoint(x: 29.71, y: 15.14))
                path.addLine(to: CGPoint(x: 37.27, y: 40.0))
                path.addLine(to: CGPoint(x: 42.0, y: 40.0))
                path.addLine(to: CGPoint(x: 54.16, y: 0.05))
                path.addLine(to: CGPoint(x: 49.42, y: 0.05))
                path.addLine(to: CGPoint(x: 39.63, y: 32.22))
                path.closeSubpath()
                path.move(to: CGPoint(x: 5.54, y: 0.05))
                path.addLine(to: CGPoint(x: 0.8, y: 0.05))
                path.addLine(to: CGPoint(x: 8.36, y: 24.9))
                path.addLine(to: CGPoint(x: 13.1, y: 24.9))
                path.addLine(to: CGPoint(x: 5.54, y: 0.05))
                path.closeSubpath()
                path.move(to: CGPoint(x: 25.11, y: 0.05))
                path.addLine(to: CGPoint(x: 12.96, y: 40.0))
                path.addLine(to: CGPoint(x: 17.69, y: 40.0))
                path.addLine(to: CGPoint(x: 29.85, y: 0.05))
                path.addLine(to: CGPoint(x: 25.11, y: 0.05))
                path.closeSubpath()
            }
        .applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                   tx: rect.minX + (rect.width - 236 * scale) / 2,
                                   ty: rect.minY + (rect.height - 40 * scale) / 2))
    }
}
