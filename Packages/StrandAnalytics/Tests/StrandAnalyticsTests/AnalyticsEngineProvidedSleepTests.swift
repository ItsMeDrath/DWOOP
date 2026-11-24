import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// #804 Fix A: a night the MOTION detector can't stage — an Oura ring sends NO gravity vector, so
/// `detectSleep` returns nothing and the night scored blank — must still score when the caller hands
/// `analyzeDay` the ring's OWN persisted hypnogram via `providedSleep`. And the byte-identical default
/// path (empty `providedSleep`) must be unchanged.
final class AnalyticsEngineProvidedSleepTests: XCTestCase {
    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

    /// Build a night [start, end) of hr (30 s) + rr (2 s, varied so RMSSD is computable) with NO gravity.
    private func nightStreams(start: Int, end: Int) -> (hr: [HRSample], rr: [RRInterval]) {
        let hr = stride(from: start, to: end, by: 30).map { HRSample(ts: $0, bpm: 52 + ($0 / 300) % 4) }
        // rrMs cycles 1080…1120 so successive differences are non-zero → a real (non-nil) RMSSD.
        var i = 0
        let rr = stride(from: start, to: end, by: 2).map { ts -> RRInterval in
            defer { i += 1 }
            return RRInterval(ts: ts, rrMs: 1080 + (i % 6) * 8)
        }
        return (hr, rr)
    }

    /// A contiguous deep/light/rem/wake hypnogram spanning [start, end), the shape #773 persists.
    private func hypnogram(start: Int) -> [StageSegment] {
        var t = start
        func seg(_ mins: Int, _ stage: String) -> StageSegment {
            let s = StageSegment(start: t, end: t + mins * 60, stage: stage); t += mins * 60; return s
        }
        return [
            seg(20, "wake"), seg(100, "light"), seg(60, "deep"), seg(60, "light"),
            seg(60, "rem"), seg(120, "light"), seg(60, "deep"), seg(60, "rem"),
            seg(40, "light"), seg(20, "wake"),
        ]   // 600 min in bed; deep 120, rem 120, light 320, wake 40
    }

    func testProvidedHypnogramScoresANightWithoutGravity() {
        let day = "2026-07-27"
        let dayStart = AnalyticsEngine.dayStartUtcSeconds(day)
        let sleepStart = dayStart - 4 * 3600          // 20:00 the previous evening
        let sleepEnd = sleepStart + 600 * 60          // +10 h → 06:00, ends on `day`
        let s = nightStreams(start: sleepStart, end: sleepEnd)
        let provided = [SleepSession(start: sleepStart, end: sleepEnd, efficiency: 0.75,
                                     stages: hypnogram(start: sleepStart), restingHR: nil, avgHRV: nil)]

        let res = AnalyticsEngine.analyzeDay(day: day, hr: s.hr, rr: s.rr, profile: profile,
                                             providedSleep: provided)

        XCTAssertNotNil(res.daily.totalSleepMin, "the provided hypnogram must score the night")
        XCTAssertEqual(res.daily.totalSleepMin ?? 0, 560, accuracy: 1)   // light 320 + deep 120 + rem 120
        XCTAssertEqual(res.daily.deepMin ?? 0, 120, accuracy: 1)
        XCTAssertEqual(res.daily.remMin ?? 0, 120, accuracy: 1)
        XCTAssertEqual(res.daily.efficiency ?? 0, 0.75, accuracy: 0.001)
        XCTAssertFalse(res.cachedSleep.isEmpty)
        // HRV & resting HR are re-derived from THIS day's rr/hr over the provided window (the ring row
        // carried neither) — the whole point of #804 (avgHrv was nil despite 36 k rr present).
        XCTAssertNotNil(res.daily.avgHrv, "avgHrv must be derived from rr over the provided sleep window")
        XCTAssertNotNil(res.daily.restingHr)
    }

    func testEmptyProvidedSleepIsByteIdenticalToOmitting() {
        let day = "2026-07-27"
        let dayStart = AnalyticsEngine.dayStartUtcSeconds(day)
        let s = nightStreams(start: dayStart - 4 * 3600, end: dayStart + 6 * 3600)

        let omitted = AnalyticsEngine.analyzeDay(day: day, hr: s.hr, rr: s.rr, profile: profile)
        let empty = AnalyticsEngine.analyzeDay(day: day, hr: s.hr, rr: s.rr, profile: profile,
                                               providedSleep: [])
        XCTAssertEqual(omitted.daily, empty.daily)
        // No gravity + no provided hypnogram = the pre-fix #804 state: the night does not score.
        XCTAssertNil(omitted.daily.totalSleepMin)
        XCTAssertNil(omitted.daily.avgHrv)
    }

    func testNapsDoNotChangeMainSleepRecoveryInputs() throws {
        let day = "2026-07-27"
        let dayStart = AnalyticsEngine.dayStartUtcSeconds(day)
        let mainStart = dayStart - 4 * 3600
        let mainEnd = mainStart + 600 * 60
        let napStart = dayStart + 12 * 3600
        let napEnd = napStart + 45 * 60

        let main = SleepSession(start: mainStart, end: mainEnd, efficiency: 0.75,
                                stages: hypnogram(start: mainStart), restingHR: 50, avgHRV: 20)
        let nap = SleepSession(start: napStart, end: napEnd, efficiency: 0.95,
                               stages: [StageSegment(start: napStart, end: napEnd, stage: "light")],
                               restingHR: 35, avgHRV: 90)
        let hrvBase = Baselines.foldHistory(Array(repeating: 20.0, count: 14), cfg: Baselines.hrvCfg)
        let rhrBase = Baselines.foldHistory(Array(repeating: 50.0, count: 14), cfg: Baselines.restingHRCfg)
        let baselines = AnalyticsEngine.ProfileBaselines(hrv: hrvBase, restingHR: rhrBase)

        XCTAssertTrue(hrvBase.usable)
        XCTAssertTrue(rhrBase.usable)
        let mainOnly = analyzeProvided(day: day, provided: [main], baselines: baselines)
        let withNap = analyzeProvided(day: day, provided: [main, nap], baselines: baselines)
        XCTAssertNotNil(mainOnly.recovery, "the main sleep alone must produce a Recovery score")

        XCTAssertEqual(withNap.daily.totalSleepMin, mainOnly.daily.totalSleepMin,
                       "a nap must not be folded into the main-night sleep total")
        XCTAssertEqual(withNap.daily.restingHr, 50,
                       "the nap's lower resting HR must not replace the main-night value")
        XCTAssertEqual(withNap.daily.avgHrv ?? 0, 20, accuracy: 0.001,
                       "the nap's HRV must not be mixed into the main-night value")
        XCTAssertEqual(try XCTUnwrap(withNap.recovery), try XCTUnwrap(mainOnly.recovery), accuracy: 1e-9,
                       "adding a nap must not change the Recovery score")
    }

    func testProvidedSessionKeepsItsOwnStoredHrvWhenPresent() {
        // A provided session that already carries restingHR/avgHRV is used verbatim (not recomputed).
        let day = "2026-07-27"
        let dayStart = AnalyticsEngine.dayStartUtcSeconds(day)
        let sleepStart = dayStart - 4 * 3600
        let sleepEnd = sleepStart + 600 * 60
        let s = nightStreams(start: sleepStart, end: sleepEnd)
        let provided = [SleepSession(start: sleepStart, end: sleepEnd, efficiency: 0.8,
                                     stages: hypnogram(start: sleepStart), restingHR: 48, avgHRV: 65)]

        let res = AnalyticsEngine.analyzeDay(day: day, hr: s.hr, rr: s.rr, profile: profile,
                                             providedSleep: provided)
        XCTAssertEqual(res.daily.restingHr, 48)
        XCTAssertEqual(res.daily.avgHrv ?? 0, 65, accuracy: 0.001)
    }

    /// Keep the public analyzeDay seam fully named and mirrored by the Kotlin twin.
    private func analyzeProvided(day: String, provided: [SleepSession],
                                 baselines: AnalyticsEngine.ProfileBaselines = AnalyticsEngine.ProfileBaselines()) -> AnalyticsEngine.DayResult {
        AnalyticsEngine.analyzeDay(
            day: day,
            hr: [],
            rr: [],
            resp: [],
            vendorResp: [],
            gravity: [],
            steps: [],
            dayHr: nil,
            daySteps: nil,
            dayGravity: nil,
            skinTemp: [],
            skinTempFamily: .whoop5,
            skinTempAnchorRaw: nil,
            spo2: [],
            profile: profile,
            baselines: baselines,
            maxHROverride: nil,
            tzOffsetSeconds: 0,
            wristOff: [],
            sleepNeedHours: AnalyticsEngine.Rest.defaultNeedHours,
            sleepConsistency: nil,
            habitualMidsleepSec: nil,
            bandSleepState: [],
            useSleepStagerV2: false,
            useMotionAwareWake: false,
            providedSleep: provided,
            sleepProvenance: .measured,
            traceSink: nil,
            hrvTraceSink: nil,
            hrvWindowDetail: false,
            deepHrvWindow: false)
    }

    /// bhelm/noop#74: a real in-bed session whose hypnogram is entirely wake has no TST,
    /// so it must not manufacture a Rest score.
    func testWakeOnlyProvidedSessionHasNoRestScore() {
        let day = "2025-06-10"
        let start = AnalyticsEngine.dayStartUtcSeconds(day) + 3600
        let end = start + 1800
        let provided = [SleepSession(
            start: start, end: end, efficiency: 0,
            stages: [StageSegment(start: start, end: end, stage: "wake")],
            restingHR: nil, avgHRV: nil)]

        XCTAssertNil(analyzeProvided(day: day, provided: provided).restScore)
    }

    /// Positive boundary: staged sleep does not require deep or REM to earn a Rest score.
    func testLightOnlyProvidedSessionHasRestScore() {
        let day = "2025-06-10"
        let start = AnalyticsEngine.dayStartUtcSeconds(day) + 3600
        let end = start + 1800
        let provided = [SleepSession(
            start: start, end: end, efficiency: 1,
            stages: [StageSegment(start: start, end: end, stage: "light")],
            restingHR: nil, avgHRV: nil)]

        XCTAssertNotNil(analyzeProvided(day: day, provided: provided).restScore)
    }
}
