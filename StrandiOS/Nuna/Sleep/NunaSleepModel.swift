#if os(iOS)
import Foundation
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// One night as the Nuna sleep screens read it: the main block group, its stage split and timeline, the
/// naps of the same day, and the cached daily row for vitals. Display only; the selection of the main
/// block, the nap classification and the stage decoding all come from the same helpers `SleepView` uses.
struct NunaNight: Identifiable {
    var id: String { dayKey }
    let dayKey: String
    let wakeDate: Date
    let onset: Date
    let wake: Date
    let stages: Stages
    let intervals: [SleepInterval]
    let naps: [NunaNap]
    let daily: DailyMetric?
    /// True when the stage split is the daily aggregate (no per-epoch timeline).
    let proportional: Bool
    /// Movement magnitude per 30 s epoch, placed in seconds from `onset`. Empty when the night has none.
    var motion: [NunaMotionEpoch] = []
    /// The stored block a sleep-time edit writes against: the same main block `SleepView` edits.
    var editTarget: CachedSleepSession?

    var asleepMin: Double { stages.asleep }
    var inBedMin: Double { stages.total }
}

struct NunaMotionEpoch { let t: TimeInterval; let v: Double }


/// Shared iPhone-only sleep need calculation for selected nights and long-range history.
enum NunaSleepNeedCalculation {
    struct Result {
        let needMin: Double
        let strainMin: Double
        let debtMin: Double
    }

    static let healthyMin = 450.0
    static let debtCarry = 0.70
    static let minimumDebtMin = 10.0
    /// DailyMetric.strain is stored as internal 0–100 Effort; sleep need uses WHOOP's 0–21 Strain.
    static let whoopStrainPerEffortPoint = 21.0 / 100.0

    /// Forecast the next sleep need from today's WHOOP-scale Strain and the debt carried forward
    /// after the latest completed night. DailyMetric.strain is stored as internal 0–100 Effort.
    static func forecastNeed(strainEffort: Double, carriedDebtMin: Double) -> Double {
        let whoopStrain = max(strainEffort.isFinite ? strainEffort : 0, 0) * whoopStrainPerEffortPoint
        let strainMin = min(whoopStrain * 3.0, 600.0 - healthyMin)
        let debtRoom = max(600.0 - healthyMin - strainMin, 0)
        let debt = carriedDebtMin >= minimumDebtMin ? min(carriedDebtMin, debtRoom) : 0
        return min(600.0, healthyMin + strainMin + debt)
    }

    static func calculate(sleep: [(day: String, mainMin: Double, napMin: Double)],
                          strainByDay: [String: Double]) -> [String: Result] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        var carriedDebt = 0.0
        var result: [String: Result] = [:]

        for night in sleep.sorted(by: { $0.day < $1.day }) where night.mainMin > 0 {
            let previousDay: String
            if let date = formatter.date(from: night.day),
               let previous = Calendar.current.date(byAdding: .day, value: -1, to: date) {
                previousDay = Repository.localDayKey(previous)
            } else {
                previousDay = ""
            }
            // The total target is capped at 10 hours, including both strain and carried debt.
            // Convert internal 0–100 Effort to WHOOP 0–21 Strain before applying 3 min per point.
            let whoopStrain = max(strainByDay[previousDay] ?? 0, 0) * whoopStrainPerEffortPoint
            let rawStrainMin = whoopStrain * 3.0
            let strainMin = min(rawStrainMin, 600.0 - healthyMin)
            let availableDebtRoom = max(600.0 - healthyMin - strainMin, 0)
            let appliedDebtMin = min(carriedDebt, availableDebtRoom)
            let needMin = min(600.0, healthyMin + strainMin + appliedDebtMin)
            let credited = SleepDebt.creditedSleepMin(mainSleepMin: night.mainMin, napSleepMin: night.napMin) ?? night.mainMin
            let calculatedDebt = debtCarry * max(0, needMin - credited)
            result[night.day] = Result(needMin: needMin, strainMin: strainMin, debtMin: appliedDebtMin)
            carriedDebt = calculatedDebt < minimumDebtMin ? 0 : calculatedDebt
        }
        return result
    }
}


/// Where the night really ended when the strap stopped recording before the session did. Movement the strap measured is never
/// exactly zero, so a run of exact zeros right after the last sleep is a stretch with no recording (the strap was off the wrist or
/// had not synced yet), and calling it "awake" would put the person in bed long after they got up. The night is cut a few minutes
/// after the last sleep at most, and only when a gap of at least `minGap` seconds starts within `reach` seconds of it. Anything
/// the strap did record stays.
enum NunaNightTail {
    static let minGap: TimeInterval = 600
    static let reach: TimeInterval = 600
    static let grace: TimeInterval = 300

    /// The new end in seconds from onset, or nil to leave the night as it is.
    static func cutoff(intervals: [SleepInterval], motion: [NunaMotionEpoch]) -> TimeInterval? {
        guard let lastSleep = intervals.filter({ $0.stage != .awake }).map(\.end).max(),
              let end = intervals.map(\.end).max(), end > lastSleep + grace else { return nil }
        let sorted = motion.sorted { $0.t < $1.t }
        var runStart: TimeInterval?
        var runEpochs = 0
        var step: TimeInterval = 30
        if sorted.count > 1 { step = max(1, sorted[1].t - sorted[0].t) }
        for e in sorted where e.t >= lastSleep - step {
            if e.v == 0 {
                if runStart == nil { runStart = e.t; runEpochs = 0 }
                runEpochs += 1
                if let r = runStart, Double(runEpochs) * step >= minGap, r <= lastSleep + reach {
                    return min(max(r, lastSleep), lastSleep + grace)
                }
            } else { runStart = nil; runEpochs = 0 }
        }
        return nil
    }
}

/// What the movement strip adds up to. Magnitudes are not calibrated, so these are relative counts:
/// a movement is a burst above `moveThreshold`, a position change a burst whose peak clears `positionPeak`,
/// and restlessness is movements per hour of sleep window.
struct NunaMovementSummary {
    static let moveThreshold = 0.3
    static let positionPeak = 6.0

    enum Level { case low, medium, high }
    let movements: Int
    let positionChanges: Int
    let level: Level

    init?(_ epochs: [NunaMotionEpoch], hours: Double) {
        guard epochs.count >= 10, hours > 0 else { return nil }
        var moves = 0, positions = 0, peak = 0.0, inBurst = false
        for e in epochs {
            if e.v > Self.moveThreshold {
                if !inBurst { moves += 1; inBurst = true; peak = 0 }
                peak = max(peak, e.v)
            } else if inBurst {
                if peak > Self.positionPeak { positions += 1 }
                inBurst = false
            }
        }
        if inBurst, peak > Self.positionPeak { positions += 1 }
        movements = moves; positionChanges = positions
        let perHour = Double(moves) / hours
        level = perHour < 6 ? .low : (perHour < 12 ? .medium : .high)
    }
}

/// One shared interpretation of the percentage of sleep spent in the High stress zone.
enum NunaSleepStressScoring {
    /// Stress component points, normalized to 0...1 for the 10% Sleep Performance weight.
    static func points(highPercent: Double?) -> Double {
        guard let value = highPercent, value.isFinite else { return 0.5 }
        if value < 1.0 { return 1.0 }
        if value < 3.0 { return 0.75 }
        if value < 6.0 { return 0.5 }
        if value < 11.0 { return 0.2 }
        return 0.0
    }

    /// Whole-number display truncates the percentage; it never rounds up.
    static func displayPercent(_ value: Double) -> Double { Double(max(0, Int(value))) }

    /// Status thresholds: optimal below 1%, sufficient below 6%, poor from 6% onward.
    static func levelValue(_ highPercent: Double) -> Double {
        100.0 - highPercent
    }
}

struct NunaNap: Identifiable {
    var id: Int { start.timeIntervalSince1970.hashValue }
    let start: Date
    let end: Date
    let asleepMin: Double
    let intervals: [SleepInterval]
    /// Movement in seconds from `start`.
    var motion: [NunaMotionEpoch] = []
    /// Added or corrected by hand (otherwise detected from the strap).
    var manual = false
    /// The stored block behind this nap, for editing its times.
    var block: CachedSleepSession?
    var spanMin: Double { end.timeIntervalSince(start) / 60 }

    /// Minutes in a stage, from the timeline.
    func minutes(_ stage: SleepStage) -> Double {
        intervals.filter { $0.stage == stage }.reduce(0) { $0 + ($1.end - $1.start) } / 60
    }
}

@MainActor
final class NunaSleepModel: ObservableObject {
    /// 0 = latest night, 1 = the one before, ...
    /// The one model the Today screen and the Sleep screen both read, so the Sleep screen opens on nights that are already loaded.
    static let shared = NunaSleepModel()

    @Published var index = 0
    @Published private(set) var nights: [NunaNight] = []
    /// metric key -> (day key -> value)
    @Published private(set) var series: [String: [String: Double]] = [:]
    @Published private(set) var sleepStressHighPct: [String: Double] = [:]
    @Published private(set) var loaded = false
    /// Only a load that read motion trims each night's silent tail (wake time, hence consistency), so only its
    /// scores are the real ones. A motion-less load (Trends, Profile, Tonight) reads the persisted score and never
    /// writes one; otherwise the last screen to load would decide whether a night shows 97 or 96.
    private var scoresUseMotion = true
    /// What the nights were last read for (see `loadKey`), so a caller that only needs the scores can tell whether a load is current.
    private(set) var loadedKey: String?
    /// The key a load with these settings leaves in `loadedKey`; the defaults are what Today loads with, and so what its scores are made from.
    static func loadKey(seq: Int, historyDays: Int = 60, includeMotion: Bool = true) -> String {
        "\(seq)-\(NunaNapPrefs.autoDetect)-\(historyDays)-\(includeMotion)"
    }
    /// Recency-weighted debt over the latest nights (same ledger the Default Sleep tab shows).
    @Published private(set) var ledger: SleepDebtLedger?
    private var importedNeed: [String: Double] = [:]
    private var fallbackNeed: Double = 450

    /// Leave it nil for the whole stretch loaded; a screen that is about the last two weeks sets it to 14.
    var maxNights: Int?
    private var reach: Int { min(nights.count, maxNights ?? Int.max) }

    var night: NunaNight? { nights.indices.contains(index) ? nights[index] : nil }
    var hasOlder: Bool { index + 1 < reach }
    var hasNewer: Bool { index > 0 }

    private static let keys = ["sleep_performance", "sleep_need_min", "sleep_debt_min", "hours_vs_needed_pct", "strain",
                               "sleep_consistency", "restorative_pct", "sleep_efficiency", "restorative_min"]

    func value(_ key: String, _ night: NunaNight? = nil) -> Double? {
        guard let n = night ?? self.night else { return nil }
        return series[key]?[n.dayKey]
    }

    // Derived per-night figures. They use the same rules as `SleepModel` (imported figure wins, else a
    // personal estimate), so the Nuna and Default screens agree.

    /// True when the night's need came from an import or the engine's own series, so it already holds strain and debt; false when it is
    /// only the personal baseline.
    func hasStoredNeed(_ n: NunaNight) -> Bool { importedNeed[n.dayKey] != nil || series["sleep_need_min"]?[n.dayKey] != nil }

    /// The healthy minimum every night's need starts from: 7.5 hours.
    static let healthyMin = 450.0

    /// Sleep debt as of each night, measured against the healthy minimum (the same recurrence the ledger uses).
    private(set) var debtByDay: [String: Double] = [:]

    func debt(_ n: NunaNight) -> Double { debtByDay[n.dayKey] ?? 0 }

    func need(_ n: NunaNight) -> Double { needByDay[n.dayKey] ?? Self.healthyMin }
    func strain(_ n: NunaNight) -> Double { strainByDay[n.dayKey] ?? 0 }

    /// Tonight's forecast: 7h30 healthy baseline + 3 minutes per WHOOP Strain point today
    /// + 70% of the sleep deficit left after the latest completed night.
    var tonightNeedMin: Double {
        let latest = nights.first
        let mainSleep = latest.map { $0.daily?.totalSleepMin ?? $0.asleepMin } ?? 0
        let napSleep = latest?.naps.reduce(0) { $0 + $1.asleepMin } ?? 0
        let carriedDebt: Double
        if let latest {
            let credited = SleepDebt.creditedSleepMin(mainSleepMin: mainSleep, napSleepMin: napSleep) ?? mainSleep
            let remaining = NunaSleepNeedCalculation.debtCarry * max(0, need(latest) - credited)
            carriedDebt = remaining < NunaSleepNeedCalculation.minimumDebtMin ? 0 : remaining
        } else {
            carriedDebt = 0
        }
        let todayKey = Repository.localDayKey(Date())
        let todayEffort = series["strain"]?[todayKey] ?? 0
        return NunaSleepNeedCalculation.forecastNeed(strainEffort: todayEffort, carriedDebtMin: carriedDebt)
    }

    private(set) var needByDay: [String: Double] = [:]
    private(set) var strainByDay: [String: Double] = [:]

    func hoursVsNeeded(_ n: NunaNight) -> Double? {
        let asleep = n.daily?.totalSleepMin ?? n.asleepMin
        return asleep > 0 ? asleep / need(n) * 100 : nil
    }

    func restorative(_ n: NunaNight) -> Double? {
        if let v = series["restorative_pct"]?[n.dayKey] { return v }
        let asleep = n.stages.asleep
        return asleep > 0 ? (n.stages.deep + n.stages.rem) / asleep * 100 : nil
    }

    func efficiency(_ n: NunaNight) -> Double? {
        if let e = n.daily?.efficiency { return e <= 1 ? e * 100 : e }
        return series["sleep_efficiency", default: [:]][n.dayKey]
    }

    /// Five-night consistency: both bedtime and wake time are considered.
    func consistency(_ n: NunaNight) -> Double? {
        guard let i = nights.firstIndex(where: { $0.id == n.id }) else { return nil }
        let window = Array(nights.dropFirst(i).prefix(NunaSleepConsistency.windowNights).reversed())
        guard window.count == NunaSleepConsistency.windowNights else { return nil }
        func clock(_ date: Date, bedtime: Bool) -> Double {
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            var minutes = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
            if minutes < 12 * 60 { minutes += 24 * 60 }
            if !bedtime && minutes < 24 * 60 { minutes += 24 * 60 }
            return minutes
        }
        return NunaSleepConsistency.score(bedTimes: window.map { clock($0.onset, bedtime: true) },
                                          wakeTimes: window.map { clock($0.wake, bedtime: false) })
    }

    /// A previously calculated score for instant first paint. The score is shown optimistically until
    /// the current night is loaded and its input fingerprint is checked.
    static func cachedSleepScore(dayKey: String) -> Double? {
        UserDefaults.standard.object(forKey: "nuna.sleepScore.v1.\(dayKey).score") as? Double
    }

    /// All previously scored nights, so long-range charts can draw their last known values immediately
    /// and replace them after the current sleep inputs have been validated.
    static func cachedSleepScores() -> [String: Double] {
        let prefix = "nuna.sleepScore.v1."
        let suffix = ".score"
        var result: [String: Double] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() {
            guard key.hasPrefix(prefix), key.hasSuffix(suffix),
                  let score = value as? Double else { continue }
            let day = String(key.dropFirst(prefix.count).dropLast(suffix.count))
            guard day.count == 10 else { continue }
            result[day] = score
        }
        return result
    }

    /// The agreed 60/20/10/10 Sleep Score. Missing data earns neutral half-credit, never a fabricated perfect score.
    /// The durable snapshot is reused only while every score input is unchanged; a corrected night, changed
    /// need/consistency, or updated sleep-stress result naturally produces a new fingerprint and score.
    func sleepScore(_ n: NunaNight) -> Double? {
        guard let hours = hoursVsNeeded(n), let efficiency = efficiency(n) else { return nil }
        func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
        let consistencyValue = consistency(n) ?? 45
        let highStress = sleepStressHighPct[n.dayKey]
        let durationPoints = clamp(hours / 100)
        let consistencyPoints = clamp(consistencyValue / 90)
        let efficiencyPoints = clamp(efficiency / 90)
        let stressPoints = NunaSleepStressScoring.points(highPercent: highStress)
        let fingerprint = [
            "v1",
            String(format: "%.8f", hours),
            String(format: "%.8f", need(n)),
            String(format: "%.8f", efficiency),
            String(format: "%.8f", consistencyValue),
            highStress.map { String(format: "%.8f", $0) } ?? "missing",
            String(n.onset.timeIntervalSince1970),
            String(n.wake.timeIntervalSince1970)
        ].joined(separator: "|")
        let fingerprintKey = "nuna.sleepScore.v1.\(n.dayKey).fingerprint"
        let scoreKey = "nuna.sleepScore.v1.\(n.dayKey).score"
        let defaults = UserDefaults.standard
        if defaults.string(forKey: fingerprintKey) == fingerprint,
           let cached = defaults.object(forKey: scoreKey) as? Double {
            return cached
        }
        // Motion-less loads keep the score the full load persisted, when there is one, and never overwrite it.
        if !scoresUseMotion, let persisted = defaults.object(forKey: scoreKey) as? Double { return persisted }
        let score = ((0.60 * durationPoints + 0.20 * consistencyPoints + 0.10 * efficiencyPoints + 0.10 * stressPoints) * 100).rounded()
        if scoresUseMotion {
            defaults.set(fingerprint, forKey: fingerprintKey)
            defaults.set(score, forKey: scoreKey)
        }
        return score
    }

    /// The Sleep Score of every loaded night, keyed by the day the night ended: the one rule the screens, Anya and the factor
    /// comparisons share (the stored `sleep_performance` series is the older formula and has no sleep stress term).
    func scoresByDay() -> [String: Double] {
        var out: [String: Double] = [:]
        for n in nights { if let s = sleepScore(n) { out[n.dayKey] = s } }
        return out
    }

    /// Debt in minutes as of the latest night, when there is one.
    var debtMin: Double? { index == 0 ? night.map { debt($0) }.flatMap { $0 > 0 ? $0 : nil } : nil }

    /// The mean of a figure over up to 14 nights before the selected one, once there are at least three of them.
    func usual(_ f: (NunaNight) -> Double?) -> Double? {
        let values = nights.dropFirst(index + 1).prefix(14).compactMap(f)
        return values.count >= 3 ? values.reduce(0, +) / Double(values.count) : nil
    }

    /// Real readings for the last `count` nights ending at the selected one, with their dates (oldest first).
    func recentPoints(count: Int = 14, _ f: (NunaNight) -> Double?) -> [(date: Date, value: Double)] {
        nights.dropFirst(index).prefix(count).reversed().compactMap { n in f(n).map { (n.wakeDate, $0) } }
    }

    /// A per-night figure for the last `count` nights ending at the selected one (oldest first).
    func recent(count: Int = 14, _ f: (NunaNight) -> Double?) -> [Double?] {
        nights.dropFirst(index).prefix(count).reversed().map(f)
    }

    /// Mean stage minutes over the nights before the selected one (up to 14), for "compared to usual".
    func typical() -> Stages? {
        let others = nights.enumerated().filter { $0.offset > index }.prefix(14).map(\.element)
            .filter { !$0.proportional || $0.stages.total > 0 }
        guard others.count >= 3 else { return nil }
        let n = Double(others.count)
        return Stages(awake: others.map { $0.stages.awake }.reduce(0, +) / n,
                      light: others.map { $0.stages.light }.reduce(0, +) / n,
                      deep: others.map { $0.stages.deep }.reduce(0, +) / n,
                      rem: others.map { $0.stages.rem }.reduce(0, +) / n)
    }

    /// Values of a series for the last `count` nights ending at the selected one (oldest first).
    func recent(_ key: String, count: Int = 14) -> [Double?] {
        let slice = nights.dropFirst(index).prefix(count).reversed()
        return slice.map { series[key]?[$0.dayKey] }
    }

    /// The naps that started inside a stretch of time, each with the night it is filed under (the key the nap detail opens on), without loading
    /// everything else the sleep screens need. A nap is a block that is not part of its day's main night.
    static func naps(from lo: Date, to hi: Date, repo: Repository) async -> [(dayKey: String, nap: NunaNap)] {
        let hab = await repo.habitualMidsleepSec()
        let sessions = await repo.allSleepSessions(days: 10)
        var out: [(dayKey: String, nap: NunaNap)] = []
        for group in SleepModel.navDays(navSessions: sessions) {
            let main = SleepView.mainNightGroup(group, habitualMidsleepSec: hab)
            guard let last = main.last else { continue }
            let key = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(last.endTs)))
            let mainStarts = Set(main.map(\.startTs))
            for b in group where !mainStarts.contains(b.startTs) && (NunaNapPrefs.autoDetect || b.userEdited) {
                let start = Date(timeIntervalSince1970: TimeInterval(b.effectiveStartTs))
                guard start >= lo, start < hi else { continue }
                let asleep = SleepView.decodeSegments(b.stagesJSON, sessionStart: b.effectiveStartTs)?.stages.asleep
                    ?? SleepView.decodedAsleepMinutes(b.stagesJSON, effectiveStartTs: b.effectiveStartTs)
                out.append((key, NunaNap(start: start, end: Date(timeIntervalSince1970: TimeInterval(b.endTs)),
                                         asleepMin: asleep, intervals: [], manual: b.userEdited, block: b)))
            }
        }
        return out.sorted { $0.nap.start < $1.nap.start }
    }

    /// `selectDayKey` or `selectIndex` pick the night to stand on in the same step that the nights are stored, so there is never a moment
    /// with the new nights and the latest one selected.
    func load(repo: Repository, selectDayKey: String? = nil, selectIndex: Int? = nil,
              historyDays: Int = 60, includeMotion: Bool = true) async {
        let keyAtStart = Self.loadKey(seq: repo.refreshSeq, historyDays: historyDays, includeMotion: includeMotion)
        scoresUseMotion = includeMotion

        // Sleep sessions, habitual timing and the independent daily metric series can all start
        // together. Previously the score waited for the first three reads before even starting
        // the metric history needed by its calculation.
        async let habTask = repo.habitualMidsleepSec()
        async let sessionsTask = repo.allSleepSessions(days: historyDays)
        async let performanceA = repo.exploreSeries(key: "sleep_performance", source: "my-whoop", days: historyDays)
        async let needA = repo.exploreSeries(key: "sleep_need_min", source: "my-whoop", days: historyDays)
        async let debtA = repo.exploreSeries(key: "sleep_debt_min", source: "my-whoop", days: historyDays)
        async let hoursA = repo.exploreSeries(key: "hours_vs_needed_pct", source: "my-whoop", days: historyDays)
        async let strainA = repo.exploreSeries(key: "strain", source: "my-whoop", days: historyDays)
        async let consistencyA = repo.exploreSeries(key: "sleep_consistency", source: "my-whoop", days: historyDays)
        async let restorativePctA = repo.exploreSeries(key: "restorative_pct", source: "my-whoop", days: historyDays)
        async let efficiencyA = repo.exploreSeries(key: "sleep_efficiency", source: "my-whoop", days: historyDays)
        async let restorativeMinA = repo.exploreSeries(key: "restorative_min", source: "my-whoop", days: historyDays)

        let (hab, sessions) = await (habTask, sessionsTask)
        let motions = includeMotion ? await repo.sessionMotions(sessions: sessions) : [:]
        var daily: [String: DailyMetric] = [:]
        for d in repo.days { daily[d.day] = d }

        var out: [NunaNight] = []
        for group in SleepModel.navDays(navSessions: sessions) {
            let main = SleepView.mainNightGroup(group, habitualMidsleepSec: hab)
            guard let first = main.first, let last = main.last else { continue }
            let mainStarts = Set(main.map(\.startTs))
            let onsetTs = SleepModel.nightOnsetTs(main)
            let wakeDate = Date(timeIntervalSince1970: TimeInterval(last.endTs))
            let key = Repository.localDayKey(wakeDate)
            let row = daily[key]

            var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
            var intervals: [SleepInterval] = []
            var found = false
            for block in main {
                let start = block.effectiveStartTs
                if let seg = SleepView.decodeSegments(block.stagesJSON, sessionStart: start) {
                    found = true
                    stages.awake += seg.stages.awake; stages.light += seg.stages.light
                    stages.deep += seg.stages.deep; stages.rem += seg.stages.rem
                    let shift = TimeInterval(start - onsetTs)
                    intervals += seg.intervals.map { SleepInterval(stage: $0.stage, start: $0.start + shift, end: $0.end + shift) }
                } else if let s = SleepView.decodeStages(block.stagesJSON) {
                    found = true
                    stages.awake += s.awake; stages.light += s.light; stages.deep += s.deep; stages.rem += s.rem
                }
            }
            var motion: [NunaMotionEpoch] = []
            for block in main {
                guard let m = motions[block.startTs] else { continue }
                let base = TimeInterval(block.effectiveStartTs - onsetTs)
                for (i, v) in m.enumerated() { motion.append(NunaMotionEpoch(t: base + TimeInterval(i) * 30, v: v)) }
            }
            var proportional = intervals.isEmpty
            if !found, let row, let asleep = row.totalSleepMin, asleep > 0 {
                let eff = row.efficiency.map { $0 > 1 ? $0 / 100 : $0 }
                let bed = (eff ?? 0) > 0 ? asleep / eff! : asleep
                stages = Stages(awake: max(0, bed - asleep), light: row.lightMin ?? 0, deep: row.deepMin ?? 0, rem: row.remMin ?? 0)
                proportional = true
            }
            _ = first

            // A stretch with no recording at the end is not time awake: end the night where the recording stopped.
            var wakeAt = wakeDate
            if let cut = NunaNightTail.cutoff(intervals: intervals, motion: motion) {
                var removedAwake = 0.0
                intervals = intervals.compactMap { iv in
                    if iv.start >= cut { if iv.stage == .awake { removedAwake += (iv.end - iv.start) / 60 }; return nil }
                    if iv.end > cut { if iv.stage == .awake { removedAwake += (iv.end - cut) / 60 }; return SleepInterval(stage: iv.stage, start: iv.start, end: cut) }
                    return iv
                }
                motion = motion.filter { $0.t < cut }
                stages = Stages(awake: max(0, stages.awake - removedAwake), light: stages.light, deep: stages.deep, rem: stages.rem)
                wakeAt = Date(timeIntervalSince1970: TimeInterval(onsetTs) + cut)
            }

            let naps: [NunaNap] = group.filter { !mainStarts.contains($0.startTs) && (NunaNapPrefs.autoDetect || $0.userEdited) }.map { b in
                let start = b.effectiveStartTs
                let seg = SleepView.decodeSegments(b.stagesJSON, sessionStart: start)
                let asleep = seg?.stages.asleep ?? SleepView.decodedAsleepMinutes(b.stagesJSON, effectiveStartTs: start)
                let nm = (motions[b.startTs] ?? []).enumerated().map { NunaMotionEpoch(t: TimeInterval($0.offset) * 30, v: $0.element) }
                return NunaNap(start: Date(timeIntervalSince1970: TimeInterval(start)),
                               end: Date(timeIntervalSince1970: TimeInterval(b.endTs)),
                               asleepMin: asleep, intervals: seg?.intervals ?? [], motion: nm, manual: b.userEdited, block: b)
            }.sorted { $0.start < $1.start }

            out.append(NunaNight(dayKey: key, wakeDate: wakeDate,
                                 onset: Date(timeIntervalSince1970: TimeInterval(onsetTs)),
                                 wake: wakeAt, stages: stages, intervals: intervals, naps: naps,
                                 daily: row, proportional: proportional, motion: motion,
                                 editTarget: SleepView.mainNightSession(group, habitualMidsleepSec: hab)))
        }
        if let selectDayKey, let i = out.firstIndex(where: { $0.dayKey == selectDayKey }) { index = i }
        else if let selectIndex, selectIndex > 0, selectIndex < out.count { index = selectIndex }
        nights = out

        // Stress history and calibration are independent of the nine metric-series reads.
        let highStressTask = Task { @MainActor in
            let history = NunaStressHistory()
            await history.ensure(days: out.map(\.wakeDate), repo: repo)
            var values: [String: Double] = [:]
            for night in out {
                if let zones = history.entries[night.dayKey]?.zones(.sleep), zones.total > 0 {
                    values[night.dayKey] = zones.high / zones.total * 100
                }
            }
            return values
        }
        let stressStatusTask = Task { @MainActor in await StressEngine.shared.status(repo: repo) }

        // All nine series were already fetching while the night sessions and motion were prepared.
        let loadedSeries = await (performanceA, needA, debtA, hoursA, strainA, consistencyA, restorativePctA, efficiencyA, restorativeMinA)
        var all: [String: [String: Double]] = [:]
        for (key, points) in zip(Self.keys, [loadedSeries.0, loadedSeries.1, loadedSeries.2, loadedSeries.3, loadedSeries.4,
                                             loadedSeries.5, loadedSeries.6, loadedSeries.7, loadedSeries.8]) {
            all[key] = Dictionary(points.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        }
        series = all

        let calculations = NunaSleepNeedCalculation.calculate(
            sleep: out.map { n in
                (day: n.dayKey, mainMin: n.daily?.totalSleepMin ?? n.asleepMin,
                 napMin: n.naps.reduce(0) { $0 + $1.asleepMin })
            },
            strainByDay: all["strain"] ?? [:]
        )
        needByDay = calculations.mapValues { $0.needMin }
        strainByDay = calculations.mapValues { $0.strainMin }
        debtByDay = calculations.mapValues { $0.debtMin }
        ledger = nil
        var highStress = await highStressTask.value
        let stressStatus = await stressStatusTask.value
        if stressStatus.isReady, let todayNight = out.first(where: { Calendar.current.isDateInToday($0.wakeDate) }) {
            let start = Calendar.current.startOfDay(for: todayNight.wakeDate)
            if let result = await StressEngine.shared.day(repo: repo, from: Int(start.timeIntervalSince1970), to: Int(Date().timeIntervalSince1970)), result.sleep.total > 0 {
                highStress[todayNight.dayKey] = result.sleep.high / result.sleep.total * 100
            }
        }
        sleepStressHighPct = highStress

        // Keep iOS Sleep Performance history on the exact score shown by the Sleep ring.
        // Imported WHOOP values and the legacy Rest composite are not interchangeable with it.
        var scoredPerformance: [String: Double] = [:]
        for night in out {
            if let score = sleepScore(night) { scoredPerformance[night.dayKey] = score }
        }
        series["sleep_performance"] = scoredPerformance
        importedNeed = repo.importedSleep.compactMapValues { $0.needMin }
        fallbackNeed = SleepModel.sleepNeedMin(days: repo.days)
        let napByDay = SleepModel.napSleepMinutesByDay(navDays: SleepModel.navDays(navSessions: sessions), habitualMidsleepSec: hab)
        ledger = SleepModel.debtLedger(days: repo.days, napSleepMinByDay: napByDay)
        if index >= out.count { index = 0 }
        loadedKey = keyAtStart
        loaded = true
    }
}

// MARK: - Formatting shared by the sleep screens

enum NunaSleepFormat {
    static func duration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        let h = m / 60, r = m % 60
        if h == 0 { return String(localized: "\(r)m") }
        return String(localized: "\(h)h \(r)m")
    }

    static func clock(_ date: Date) -> String {
        AppClock.hourMinuteFormatter().string(from: date)
    }

    static func nightTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return f.string(from: date)
    }
}
#endif
