#if os(iOS)
import Foundation
import SwiftUI
import StrandAnalytics
import WhoopStore

/// Everything the Nuna Today screen shows for one selected day.
///
/// This is a deliberately smaller twin of the loading in `LiquidTodayView.load()`: the same repository
/// reads and the same resolvers (`ChargeDisplay`, `TodayView.freshRestScore`, `StrainScorer.effectiveEffort`,
/// `StressModel`), without the sparkline, hosted-card and day-cycle machinery that Nuna does not draw.
/// Display only: nothing is computed or stored differently.
@MainActor
final class NunaTodayModel: ObservableObject {
    private static let homeSnapshotKey = "nuna.home.snapshot.v1"
    /// Keep restored same-day values visible until their fresh independent reads settle.
    private var restoredHomeSnapshot = false

    /// One compact, date-scoped copy of the values needed to paint the Home metrics immediately.
    /// Historical samples and chart series remain in their existing stores.
    private struct StressPointSnapshot: Codable {
        let hour, startTs: Int
        let level, meanHR, rmssd: Double?
        let maskedForActivity: Bool

        init(_ point: DaytimeStress.HourPoint) {
            hour = point.hour; startTs = point.startTs; level = point.level
            meanHR = point.meanHR; rmssd = point.rmssd; maskedForActivity = point.maskedForActivity
        }

        var point: DaytimeStress.HourPoint {
            DaytimeStress.HourPoint(hour: hour, startTs: startTs, level: level, meanHR: meanHR,
                                    rmssd: rmssd, maskedForActivity: maskedForActivity)
        }
    }

    private struct StressCurveSnapshot: Codable {
        let hours, timeline: [StressPointSnapshot]
        let sustainedHigh: Bool
        let sustainedRun, activityMaskedHours, highStressMinutes: Int
        let dayMean: Double?
        let peak: StressPointSnapshot?
        let hrOnlyFallback: Bool

        init(_ result: DaytimeStress.Result) {
            hours = result.hours.map(StressPointSnapshot.init)
            timeline = result.timeline.map(StressPointSnapshot.init)
            sustainedHigh = result.sustainedHigh; sustainedRun = result.sustainedRun
            activityMaskedHours = result.activityMaskedHours; highStressMinutes = result.highStressMinutes
            dayMean = result.dayMean; peak = result.peak.map(StressPointSnapshot.init)
            hrOnlyFallback = result.hrOnlyFallback
        }

        var result: DaytimeStress.Result {
            DaytimeStress.Result(hours: hours.map(\.point), sustainedHigh: sustainedHigh,
                sustainedRun: sustainedRun, dayMean: dayMean, peak: peak?.point,
                activityMaskedHours: activityMaskedHours, highStressMinutes: highStressMinutes,
                hrOnlyFallback: hrOnlyFallback, timeline: timeline.map(\.point))
        }
    }

    struct HighlightNapSnapshot: Codable {
        let id: String
        let duration: String
        let endTs: Int
    }

    private struct HomeSnapshot: Codable {
        let version: Int
        let dayKey: String
        let savedAt: Date
        let chargeKind: String
        let chargeValue: Double?
        let chargeCaption: String?
        let chargeNights: Int?
        let effort, rest, stress, hrv, restingHr, respiratory, spo2, steps, calories, sleepMinutes: Double?
        let extras, previous: [String: Double]
        let stressLoaded: Bool
        /// Bounded daily history used by the Health monitor's personal ranges.
        let monitorSeries: [String: [String: Double]]?
        /// Bounded display points for optional Detailed Key Metrics tiles.
        let keySparkSeries: [String: [Double]]?
        let stressStatusReady: Bool?
        let stressStatusNights: Int?
        let stressBaseline: Double?
        let stressTypicalMin: Int?
        let stressCurve: StressCurveSnapshot?
        let highlightNaps: [HighlightNapSnapshot]?
    }

    private func restoreHomeSnapshot() {
        guard let data = UserDefaults.standard.data(forKey: Self.homeSnapshotKey),
              let snapshot = try? JSONDecoder().decode(HomeSnapshot.self, from: data),
              snapshot.version == 1,
              snapshot.dayKey == Repository.localDayKey(Date()) else { return }
        restoredHomeSnapshot = true
        switch snapshot.chargeKind {
        case "scored": charge = .scored(pct: snapshot.chargeValue ?? 0)
        case "carried": charge = .carried(pct: snapshot.chargeValue ?? 0, caption: snapshot.chargeCaption ?? "")
        case "calibrating": charge = .calibrating(nights: snapshot.chargeNights ?? 0)
        default: charge = .noData
        }
        effort = snapshot.effort
        rest = snapshot.rest
        stress = snapshot.stress
        hrv = snapshot.hrv
        restingHr = snapshot.restingHr
        respiratory = snapshot.respiratory
        spo2 = snapshot.spo2
        steps = snapshot.steps
        calories = snapshot.calories
        sleepMinutes = snapshot.sleepMinutes
        extras = snapshot.extras
        previous = snapshot.previous
        stressLoaded = snapshot.stressLoaded
        monitorSeries = snapshot.monitorSeries ?? [:]
        keySparkSeries = snapshot.keySparkSeries ?? [:]
        stressStatus = snapshot.stressStatusReady == true ? .ready : .calibrating(nights: snapshot.stressStatusNights ?? 0)
        stressBaseline = snapshot.stressBaseline
        stressTypicalMin = snapshot.stressTypicalMin
        stressCurve = snapshot.stressCurve?.result
        highlightNaps = snapshot.highlightNaps ?? []
    }

    private func persistHomeSnapshot(dayKey: String) {
        guard dayOffset == 0, dayKey == Repository.localDayKey(Date()) else { return }
        let kind: String
        let value: Double?
        let caption: String?
        let nights: Int?
        switch charge {
        case .scored(let pct): kind = "scored"; value = pct; caption = nil; nights = nil
        case .carried(let pct, let text): kind = "carried"; value = pct; caption = text; nights = nil
        case .calibrating(let count): kind = "calibrating"; value = nil; caption = nil; nights = count
        case .noData: kind = "noData"; value = nil; caption = nil; nights = nil
        }
        let snapshot = HomeSnapshot(version: 1, dayKey: dayKey, savedAt: Date(),
            chargeKind: kind, chargeValue: value, chargeCaption: caption, chargeNights: nights,
            effort: effort, rest: rest, stress: stress, hrv: hrv, restingHr: restingHr,
            respiratory: respiratory, spo2: spo2, steps: steps, calories: calories,
            sleepMinutes: sleepMinutes, extras: extras, previous: previous, stressLoaded: stressLoaded,
            monitorSeries: Self.boundedMonitorSeries(monitorSeries), keySparkSeries: Self.boundedSparkSeries(keySparkSeries),
            stressStatusReady: stressStatus.isReady, stressStatusNights: stressStatus.nights,
            stressBaseline: stressBaseline, stressTypicalMin: stressTypicalMin,
            stressCurve: stressCurve.map(StressCurveSnapshot.init), highlightNaps: highlightNaps)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.homeSnapshotKey)
    }

    /// Keep the monitor history in the same single Home snapshot as the score values.
    /// At most 30 daily readings per monitored vital are retained.
    private static func boundedMonitorSeries(_ input: [String: [String: Double]]) -> [String: [String: Double]] {
        var result: [String: [String: Double]] = [:]
        for (metric, values) in input {
            let valid = values.filter { $0.value.isFinite }.sorted { $0.key < $1.key }.suffix(30)
            if !valid.isEmpty { result[metric] = Dictionary(uniqueKeysWithValues: valid.map { ($0.key, $0.value) }) }
        }
        return result
    }

    /// Detailed tiles can show up to six months; cap each metric at 180 values.
    private static func boundedSparkSeries(_ input: [String: [Double]]) -> [String: [Double]] {
        input.reduce(into: [:]) { result, entry in
            let values = entry.value.filter(\.isFinite).suffix(180)
            if !values.isEmpty { result[entry.key] = Array(values) }
        }
    }

    func updateMonitorSeries(_ values: [String: [String: Double]]) {
        monitorSeries = Self.boundedMonitorSeries(values)
        if loaded { persistHomeSnapshot(dayKey: Repository.localDayKey(Date())) }
    }

    func updateKeySparkSeries(_ values: [String: [Double]]) {
        keySparkSeries = Self.boundedSparkSeries(values)
        if loaded { persistHomeSnapshot(dayKey: Repository.localDayKey(Date())) }
    }

    func updateHighlightNaps(_ naps: [NunaNap]) {
        let now = Date()
        highlightNaps = naps.filter { $0.end <= now && now.timeIntervalSince($0.end) <= 3 * 3600 }
            .map { HighlightNapSnapshot(id: "nap-\(Int($0.start.timeIntervalSince1970))",
                                        duration: NunaHighlightEngine.hm($0.asleepMin),
                                        endTs: Int($0.end.timeIntervalSince1970)) }
        if loaded { persistHomeSnapshot(dayKey: Repository.localDayKey(Date())) }
    }

    init() {
        restoreHomeSnapshot()
    }

    /// 0 = today, 1 = yesterday, ...
    /// Picking another day moves the Sleep score at once from the nights already loaded, the way Charge and Effort follow the day, instead of
    /// waiting for the reload that follows.
    @Published var dayOffset = 0 { didSet {
        if dayOffset != oldValue {
            stressLoaded = false
            stress = nil
            stressCurve = nil
            stressBaseline = nil
            stressWhoop = nil
            selectCachedSleepNight()
        }
    } }

    @Published private(set) var day: DailyMetric?
    @Published private(set) var charge: LiquidTodayView.ChargeDisplay = .noData
    /// Stored Effort on NOOP's 0-100 axis (live for today, stored for past days).
    @Published private(set) var effort: Double?
    @Published private(set) var rest: Double?
    @Published private(set) var stress: Double?
    @Published private(set) var hrv: Double?
    @Published private(set) var restingHr: Double?
    @Published private(set) var respiratory: Double?
    @Published private(set) var spo2: Double?
    @Published private(set) var steps: Double?
    @Published private(set) var calories: Double?
    @Published private(set) var sleepMinutes: Double?
    @Published private(set) var workouts: [WorkoutRow] = []
    /// Latest value of the slower-moving metrics the Your Cards section can show.
    @Published private(set) var extras: [String: Double] = [:]
    /// Small, date-scoped histories restored with the Home snapshot.
    @Published private(set) var monitorSeries: [String: [String: Double]] = [:]
    @Published private(set) var keySparkSeries: [String: [Double]] = [:]
    @Published private(set) var highlightNaps: [HighlightNapSnapshot] = []
    @Published private(set) var loaded = false
    /// Stress has its own readiness: it can be shown as soon as its independent calculation finishes.
    @Published private(set) var stressLoaded = false
    /// The one-line readiness read the Default Today synthesis uses, so both experiences say the same thing.
    @Published private(set) var readiness: ReadinessEngine.Readiness?
    /// Today's hourly stress curve (nil on past days or when it could not be scored).
    @Published private(set) var stressCurve: DaytimeStress.Result?
    /// Typical high-stress minutes for today's weekday, for the Stress card's comparison; today only, and only once it has been worked out.
    @Published private(set) var stressTypicalMin: Int?
    /// The wearer's usual stress, 0 to 3, for the Stress card's arrow.
    @Published private(set) var stressBaseline: Double?
    /// Whether the stress reading is ready or still learning the person (it needs 14 nights). While it is not ready every stress field here is
    /// nil: nothing about stress is shown until the baseline is complete.
    @Published private(set) var stressStatus: StressStatus = .calibrating(nights: 0)
    /// The WHOOP-reference reading of the day on show, with its three categories (Total day, Non-activity, Sleep).
    @Published private(set) var stressWhoop: WhoopStress.Result?
    /// Change against the previous day that has a value: HRV in ms, resting HR in bpm.
    @Published private(set) var hrvDelta: Double?
    @Published private(set) var restingHrDelta: Double?
    @Published private(set) var respiratoryDelta: Double?
    @Published private(set) var spo2Delta: Double?
    /// The reading before the one shown, for the figures that compare with it (steps, calories, sleep, stress, weight, skin temperature and the
    /// weekly Fitness Age and VO2max), keyed `steps`, `calories`, `sleep`, `stress`, `weight`, `skin_temp`, `body_age`,
    /// `vo2max_est`. A key is missing when there is no earlier reading. HRV, resting heart rate, respiratory rate and blood oxygen
    /// keep their deltas above.
    @Published private(set) var previous: [String: Double] = [:]
    private let sleepModel = NunaSleepModel.shared
    /// Exact per-night scores from the same model used by the Sleep screen. Other screens use this
    /// instead of independently re-scoring the same night from long-range trend data.
    var sleepScoresByDay: [String: Double] { sleepModel.loaded ? sleepModel.scoresByDay() : [:] }
    /// What the sleep model was last loaded for. Changing the day only picks another night out of it, so it is not read again until the data
    /// refreshes or the nap setting changes; reloading 60 days of sessions on every date change is what made the Sleep score lag behind
    /// Charge and Effort.
    private var sleepLoadKey: String?
    /// The last Effort worked out for each day, live heart rate included. Scoring a day's heart rate is the slowest step in `load`, so the ring
    /// starts from this (or the stored figure) and `load` replaces it. Effort never drops (`effectiveEffort` floors at what is earned), so a
    /// remembered figure can only be at or below the new one.
    private static var lastEffort: [String: Double] = [:]
    /// The day the current `effort` was set for, so `applyDaily` seeds it once per day and never overwrites a figure `load` has already scored.
    private var effortKey: String?

    var isToday: Bool { dayOffset == 0 }

    /// Stands the shared sleep model on the picked day's night and takes its score, with no loading. Nothing happens until it has loaded once.
    private func selectCachedSleepNight() {
        guard sleepModel.loaded else { return }
        let key = Repository.localDayKey(selectedLogicalDay)
        if let i = sleepModel.nights.firstIndex(where: { $0.dayKey == key }) {
            sleepModel.index = i
            rest = sleepModel.sleepScore(sleepModel.nights[i])
        } else {
            sleepModel.index = 0
            rest = nil
        }
    }

    /// Re-reads today's stress curve on its own, so the Stress card and screen follow the day without a full reload. Cheap when no new
    /// heart rate has arrived: the curve is memoised on a fingerprint of today's samples.
    func refreshStress(repo: Repository) async {
        guard isToday else { return }
        let status = await StressEngine.shared.status(repo: repo)
        let whoop = status.isReady ? await StressDayCurve.whoopToday(repo: repo, now: Date()) : nil
        if whoop != stressWhoop || status != stressStatus { applyStress(whoop, status: status, today: true, remember: repo) }
    }

    /// The last Charge scored for a day, so the ring is drawn on the first frame after a relaunch, before the history is read.
    private static func persistedChargeKey(dayKey: String) -> String { "nuna.today.charge.last.\(dayKey)" }

    /// A persisted same-day fallback for the Home tile while the latest HR samples are being scored.
    private static func persistedStressKey(dayKey: String) -> String { "nuna.today.stress.last.\(dayKey)" }

    /// The last stress reading per day and refresh, so the Stress screen opens with it drawn instead of building it again.
    private static var stressCache: [String: (status: StressStatus, whoop: WhoopStress.Result?)] = [:]
    private func stressCacheKey(_ repo: Repository) -> String { "\(repo.refreshSeq)-\(dayOffset)" }

    /// Synchronous: puts the last stress reading for this day on screen at once. True when there was one.
    @discardableResult
    func seedStress(repo: Repository) -> Bool {
        guard let hit = Self.stressCache[stressCacheKey(repo)] else { return false }
        applyStress(hit.whoop, status: hit.status, today: isToday, remember: nil)
        return true
    }

    /// Synchronous first paint from data already in memory. Never show a sleep score from a previous repository revision.
    func seedFromMemory(repo: Repository) {
        applyDaily(repo: repo)
        let expected = NunaSleepModel.loadKey(repo: repo)
        if sleepModel.loaded, sleepModel.loadedKey == expected {
            selectCachedSleepNight()
            sleepLoadKey = "\(repo.refreshSeq)-\(NunaNapPrefs.autoDetect)"
        } else {
            // Show the last completed-night score immediately; NunaSleepModel validates its input
            // fingerprint after loading and replaces it only if this night's data has changed.
            rest = NunaSleepModel.cachedSleepScore(dayKey: dayKey(repo: repo))
        }
        // Keep the most recent same-day stress reading visible on the first frame after relaunch.
        // The live stress calculation below replaces it as soon as fresh heart-rate data is ready.
        if isToday,
           let cached = UserDefaults.standard.object(forKey: Self.persistedStressKey(dayKey: dayKey(repo: repo))) as? NSNumber {
            stress = min(max(cached.doubleValue, 0), 3)
            stressLoaded = false
        }
        _ = seedStress(repo: repo)
    }

    /// Takes a reading (or none, while calibrating) and sets every stress field from it.
    private func applyStress(_ w: WhoopStress.Result?, status: StressStatus, today: Bool, remember repo: Repository? = nil) {
        if let repo { Self.stressCache[stressCacheKey(repo)] = (status, w) }
        stressStatus = status
        stressWhoop = w
        guard let w else {
            stressCurve = nil
            stressBaseline = nil
            // Keep the last valid reading visible while fresh HR data is unavailable.
            stressLoaded = (stress == nil)
            return
        }
        stressLoaded = true
        stressCurve = WhoopStress.daytimeResult(w, tzOffsetSeconds: TimeZone.current.secondsFromGMT())
        if today {
            if let current = w.current {
                let value = min(max(current, 0), 3)
                stress = value
                let stressDayKey = repo.map { dayKey(repo: $0) } ?? Repository.localDayKey(Date())
                UserDefaults.standard.set(value, forKey: Self.persistedStressKey(dayKey: stressDayKey))
            }
        } else {
            let waking = w.epochs.filter { $0.kind == .waking }.compactMap(\.level)
            if !waking.isEmpty { stress = waking.reduce(0, +) / Double(waking.count) }
        }
        // After calibration the person's usual waking state sits at neutral, 1.5: that is what the baseline is set from.
        stressBaseline = 1.5
    }

    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -dayOffset, to: base) ?? base
    }

    func dayKey(repo: Repository) -> String {
        if dayOffset == 0, let key = repo.today?.day { return key }
        return Repository.localDayKey(selectedLogicalDay)
    }

    /// Date shown in the header pill.
    var displayDate: Date { selectedLogicalDay }

    /// Everything that is already in memory for the day on show: the Charge score, the vitals and their changes, the readiness read, sleep minutes and
    /// the strap's step count. It reads nothing from the store and never suspends, so a detail page can call it before its first await and have these
    /// figures drawn at once instead of after the long reads in `load`, which fills in the rest. `load` runs it first, so the two always agree.
    @discardableResult
    func applyDaily(repo: Repository) -> (key: String, today: Bool, row: DailyMetric?) {
        let key = dayKey(repo: repo)
        let today = isToday
        let row = today ? (repo.today ?? repo.days.last(where: { $0.day == key }))
                        : repo.days.last(where: { $0.day == key })
        day = row

        // Charge, with the same carry / calibration rules as the other Today screens.
        // Only once the history has been read: before that `repo.days` is empty, which reads as "calibrating, 0 nights" and drew a
        // "Calibrating Recovery" card and a blank ring on every launch until the first refresh landed. Until then the last scored
        // Charge for today (kept below) stands in, so the ring is there on the first frame.
        if repo.loaded {
            let calNights = today
                ? RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv), dayKeys: repo.days.map(\.day),
                                                   hasRecovery: row?.recovery != nil)
                : nil
            let prior = TodayView.lastScoredRecoveryDay(days: repo.days, selectedDayKey: key, isToday: today,
                                                        todayScored: row?.recovery != nil, isCalibrating: calNights != nil)
            charge = LiquidTodayView.ChargeDisplay.resolve(todayRecovery: row?.recovery, priorScored: prior,
                                                           calibrationNights: calNights, todayKey: key)
            if today, case .scored(let p) = charge { UserDefaults.standard.set(p, forKey: Self.persistedChargeKey(dayKey: key)) }
        } else if today, let p = UserDefaults.standard.object(forKey: Self.persistedChargeKey(dayKey: key)) as? Double {
            charge = .scored(pct: p)
        }

        // Vitals carried from the last night that has them (today only; a past day shows its own row).
        hrv = row?.avgHrv ?? (today ? Repository.lastHrvDay(days: repo.days, todayKey: key)?.avgHrv : nil)
        restingHr = (row?.restingHr ?? (today ? Repository.lastRestingHrDay(days: repo.days, todayKey: key)?.restingHr : nil)).map(Double.init)
        respiratory = row?.respRateBpm ?? (today ? Repository.lastRespDay(days: repo.days, todayKey: key)?.respRateBpm : nil)
        // Calibrated reading first; then the strap's estimate (experiment on), carried a few days like the other vitals.
        spo2 = row?.spo2Pct ?? (today ? Repository.lastSpo2Day(days: repo.days, todayKey: key)?.spo2Pct : nil)
            ?? repo.spo2Estimate(dayKey: key, carry: today)
        // Skin temperature is also a nightly reading. Seed it from the already-loaded daily rows,
        // retaining the same absolute-vs-deviation scale rule as Repository.exploreSeries.
        let skinRows = repo.days.compactMap { metric -> (day: String, value: Double)? in
            metric.skinTempDevC.map { (day: metric.day, value: $0) }
        }
        if let skinKind = SkinTempDisplay.dominantKind(valuesAscendingByDay: skinRows.map(\.value)),
           let latestSkin = skinRows.last(where: { SkinTempDisplay.kind(of: $0.value) == skinKind }) {
            extras["skin_temp"] = latestSkin.value
        } else {
            extras.removeValue(forKey: "skin_temp")
        }
        sleepMinutes = row?.totalSleepMin
        readiness = ReadinessEngine.evaluate(days: repo.days, today: key)
        // Change against the night BEFORE the one the value came from. A value carried from the last
        // scored night is compared with the night before that, not with itself.
        func change(_ value: Double?, source: DailyMetric?, _ field: (DailyMetric) -> Double?) -> Double? {
            guard let value, let src = source ?? row else { return nil }
            guard let prev = repo.days.last(where: { $0.day < src.day && field($0) != nil }), let p = field(prev) else { return nil }
            return value - p
        }
        let hrvSrc = row?.avgHrv != nil ? row : (today ? Repository.lastHrvDay(days: repo.days, todayKey: key) : nil)
        let rhrSrc = row?.restingHr != nil ? row : (today ? Repository.lastRestingHrDay(days: repo.days, todayKey: key) : nil)
        let respSrc = row?.respRateBpm != nil ? row : (today ? Repository.lastRespDay(days: repo.days, todayKey: key) : nil)
        let spo2Src = row?.spo2Pct != nil ? row : (today ? Repository.lastVitalsDay(days: repo.days, todayKey: key) : nil)
        hrvDelta = change(hrv, source: hrvSrc) { $0.avgHrv }
        restingHrDelta = change(restingHr, source: rhrSrc) { $0.restingHr.map(Double.init) }
        respiratoryDelta = change(respiratory, source: respSrc) { $0.respRateBpm }
        spo2Delta = change(spo2, source: spo2Src) { $0.spo2Pct }
        // The strap's own count, when the day has one; `load` goes on to Apple Health and the estimate for a day without.
        if let counted = row?.steps { steps = Double(counted) }
        // The ring's Effort: the last scored figure for this day, else the stored one. `load` scores the day's heart rate and replaces it.
        if effortKey != key {
            effort = Self.lastEffort[key].flatMap { StrainScorer.effectiveEffort(live: $0, stored: row?.strain) }
                ?? StrainScorer.effectiveEffort(live: nil, stored: row?.strain)
            effortKey = key
        }
        return (key, today, row)
    }

    func load(repo: Repository, profile: ProfileStore) async {
        let (key, today, row) = applyDaily(repo: repo)
        // The repository has not read its history yet (a launch): every figure below would be worked out from nothing and then again a moment
        // later. The refresh that finishes it bumps `refreshSeq`, which runs this again with the real data.
        guard repo.loaded else { return }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedLogicalDay)
        let from = Int(dayStart.timeIntervalSince1970)
        let to: Int = today ? Int(Date().timeIntervalSince1970)
                            : Int((cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)

        // Start independent dashboard reads together. The previous sequence waited for live HR, then sleep history,
        // then each metric series one by one, keeping otherwise-ready tiles empty.
        let curveNow = today ? Date() : (cal.date(byAdding: .second, value: -1, to: cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart) ?? dayStart)
        let sleepKey = "\(repo.refreshSeq)-\(NunaNapPrefs.autoDetect)"
        let needsSleepReload = !sleepModel.loaded || sleepLoadKey != sleepKey
        if needsSleepReload {
            // Keep the persisted completed-night score visible while the current inputs are validated.
            rest = NunaSleepModel.cachedSleepScore(dayKey: key)
        }
        if Self.stressCache[stressCacheKey(repo)] == nil && !restoredHomeSnapshot {
            stressLoaded = false
            stress = nil
            stressCurve = nil
            stressBaseline = nil
            stressWhoop = nil
        }

        // Sleep is deliberately independent from today's live Strain calculation. Start it now,
        // but publish its result when ready instead of making the dashboard wait for it.
        let requestedDayOffset = dayOffset
        let requestedRefreshSeq = repo.refreshSeq
        let sleepRefreshTask = Task { @MainActor [weak self] in
            if needsSleepReload {
                await sleepModel.load(repo: repo)
                guard let self else { return }
                self.sleepLoadKey = sleepKey
            }
            guard let self, self.dayOffset == requestedDayOffset,
                  repo.refreshSeq == requestedRefreshSeq else { return }
            let pickedNight = sleepModel.nights.firstIndex(where: { $0.dayKey == key })
            sleepModel.index = pickedNight ?? 0
            self.rest = pickedNight.flatMap { sleepModel.sleepScore(sleepModel.nights[$0]) }
        }
        let hrTask = today ? Task { await repo.hrSamples(from: from, to: to, limit: 200_000) } : nil
        let stressRefreshTask = Task { @MainActor [weak self] in
            // Score stress only after the latest Home heart-rate read has completed.
            if let hrTask { _ = await hrTask.value }
            let status = await StressEngine.shared.status(repo: repo)
            let whoop = status.isReady ? await StressDayCurve.whoopToday(repo: repo, now: curveNow) : nil
            guard let self, self.dayOffset == requestedDayOffset, repo.refreshSeq == requestedRefreshSeq else { return }
            self.applyStress(whoop, status: status, today: today, remember: repo)
        }
        let stepsTask = Task { await repo.exploreSeries(key: "steps_est", source: "my-whoop") }
        let appleTask = Task { await repo.appleDailyRows() }
        let workoutsTask = Task { await repo.workoutRows() }
        let kcalTask = Task { await repo.exploreSeries(key: "energy_kcal", source: "my-whoop", days: 30) }
        let bodyAgeTask = Task { await repo.exploreSeries(key: "body_age", source: "my-whoop", days: 60) }
        let vo2Task = Task { await repo.exploreSeries(key: "vo2max_est", source: "my-whoop", days: 60) }
        let skinTask = Task { await repo.exploreSeries(key: "skin_temp", source: "my-whoop", days: 60) }
        let weightsTask = Task { await repo.exploreSeries(key: "weight", source: "apple-health", days: 90) }

        // Live Effort for today over midnight..now, stored Effort otherwise.
        // This is intentionally allowed to finish independently of the Sleep model above.
        let live: Double?
        if let hrTask {
            let hr = await hrTask.value
            let maxHR = profile.age > 0 ? StrainScorer.tanakaHRmax(age: Double(profile.age)) : nil
            let restHR = row?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
            live = StrainScorer.strain(hr, maxHR: maxHR, restingHR: restHR, method: PuffinExperiment.effortMethod, sex: profile.sex)
        } else {
            live = nil
        }
        effort = StrainScorer.effectiveEffort(live: live, stored: row?.strain)
        effortKey = key
        if let effort { Self.lastEffort[key] = effort }

        // Steps and calories: measured on the strap first, then Apple Health, then the on-device estimate.
        let stepsSeries = await stepsTask.value
        let stepsByDay = Dictionary(stepsSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        let estSteps = stepsByDay[key] ?? (today ? stepsSeries.last?.value : nil)
        let appleKey = TodayView.appleHealthDayKey(selectedDayKey: key, localDayKey: Repository.localDayKey(Date()), isToday: today)
        let apple = await appleTask.value
        let appleSteps = apple.filter { $0.day == appleKey }.compactMap { $0.steps }.max()
        let appleKcal = apple.filter { $0.day == appleKey }.compactMap { $0.activeKcal }.max()
        steps = row?.steps.map(Double.init) ?? appleSteps.map(Double.init) ?? estSteps
        // The calories page reads the stored `energy_kcal` series first, so the card does too (the latest day for today, as the steps do).
        let kcalSeries = (await kcalTask.value).filter { $0.value > 0 }
        let kcalByDay = Dictionary(kcalSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        calories = kcalByDay[key] ?? appleKcal ?? row?.activeKcalEst ?? (today ? kcalSeries.last?.value : nil)

        var ex: [String: Double] = [:]
        var prev: [String: Double] = [:]
        for (k, points) in [("body_age", await bodyAgeTask.value), ("vo2max_est", await vo2Task.value), ("skin_temp", await skinTask.value)] {
            if let v = points.last?.value { ex[k] = v }
            if points.count >= 2 { prev[k] = points[points.count - 2].value }
        }
        let weights = await weightsTask.value
        if let w = weights.last?.value { ex["weight"] = w }
        if weights.count >= 2 { prev["weight"] = weights[weights.count - 2].value }
        extras = ex

        // The day before the one shown, for the figures that are a day's total.
        let prevKey = Repository.localDayKey(cal.date(byAdding: .day, value: -1, to: selectedLogicalDay) ?? selectedLogicalDay)
        let prevDay = repo.days.first(where: { $0.day == prevKey })
        if let s = prevDay?.steps.map(Double.init) ?? apple.filter({ $0.day == prevKey }).compactMap({ $0.steps }).max().map(Double.init) ?? stepsByDay[prevKey] {
            prev["steps"] = s
        }
        if let c = kcalByDay[prevKey] ?? apple.filter({ $0.day == prevKey }).compactMap({ $0.activeKcal }).max() ?? prevDay?.activeKcalEst { prev["calories"] = c }
        if let m = repo.days.last(where: { $0.day < key && $0.totalSleepMin != nil })?.totalSleepMin { prev["sleep"] = m }
        previous = prev
        // Workout rows were fetched alongside the other dashboard reads.
        workouts = (await workoutsTask.value).filter { $0.startTs >= from && $0.startTs < to }
        loaded = true
        // Persist one complete snapshot only after the independent Sleep and Stress refreshes have both settled.
        // The previous snapshot remains intact if this load is cancelled or superseded.
        Task { @MainActor [weak self] in
            await sleepRefreshTask.value
            await stressRefreshTask.value
            guard let self, self.dayOffset == requestedDayOffset,
                  repo.refreshSeq == requestedRefreshSeq, self.loaded else { return }
            self.persistHomeSnapshot(dayKey: key)
        }
        if today {
            // After the screen is up: it reads four earlier days of heart rate, once a day.
            stressTypicalMin = StressTypical.cached()
            Task { @MainActor [weak self] in
                let typical = await StressTypical.load(repo: repo)
                guard let self, self.dayOffset == requestedDayOffset,
                      repo.refreshSeq == requestedRefreshSeq else { return }
                self.stressTypicalMin = typical
                if self.loaded { self.persistHomeSnapshot(dayKey: key) }
            }
        } else {
            stressTypicalMin = nil
        }
    }
}
#endif
