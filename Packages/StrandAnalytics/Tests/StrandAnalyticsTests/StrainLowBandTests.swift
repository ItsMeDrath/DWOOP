import XCTest
import Foundation
@testable import StrandAnalytics
import WhoopProtocol

/// Banister's calibrated low band: zero below 11% HRR, a linear ramp to 0.0094 TRIMP/min
/// at 30% HRR, then the Banister excess above its 30% anchor added to that same 0.0094.
final class StrainLowBandTests: XCTestCase {

    private let rest = 64.0, max = 191.0

    private func flat(_ bpm: Int, minutes: Int) -> [HRSample] {
        (0 ..< minutes * 60).map { HRSample(ts: $0, bpm: bpm) }
    }

    private func oneMinuteRate(_ bpm: Int, restingHR: Double = 64, maxHR: Double = 164) -> Double {
        let hr = [HRSample(ts: 0, bpm: bpm)]
        return StrainScorer.banisterTRIMP(
            hr, restingHR: restingHR, hrReserve: maxHR - restingHR, durations: [1.0],
            b: StrainScorer.banisterBMen,
            floorRatePerMinute: StrainScorer.banisterBaselineRatePerMinute(b: StrainScorer.banisterBMen),
            lowBandPeakPerMinute: StrainScorer.banisterLowBandPeakPerMinute
        )
    }

    func testTheBandBoundsAndPeakAreCalibrated() {
        XCTAssertEqual(StrainScorer.banisterLowBandStartHRR, 0.11, accuracy: 1e-12)
        XCTAssertEqual(StrainScorer.banisterLowBandEndHRR, 0.30, accuracy: 1e-12)
        XCTAssertEqual(StrainScorer.banisterLowBandPeakPerMinute, 0.0094, accuracy: 1e-12)
        XCTAssertEqual(StrainScorer.banisterAnchorHRR, 0.30, accuracy: 1e-12)
    }

    /// Below 11% HRR earns nothing, however long it lasts.
    func testBelowTheBandEarnsNothing() {
        XCTAssertEqual(StrainScorer.strain(flat(70, minutes: 600), maxHR: max, restingHR: rest, method: .banister), 0.0)
    }

    /// At the midpoint of the ramp, 900 minutes accrue 900 × 0.0047 = 4.23 TRIMP.
    func testFifteenHoursAtMidpointOfBandAccruesAbout423TRIMP() {
        let hr = flat(90, minutes: 15)
        let durations = Array(repeating: 1.0, count: hr.count)
        let trimp = StrainScorer.banisterTRIMP(
            hr, restingHR: rest, hrReserve: max - rest, durations: durations,
            b: StrainScorer.banisterBMen,
            floorRatePerMinute: StrainScorer.banisterBaselineRatePerMinute(b: StrainScorer.banisterBMen),
            lowBandPeakPerMinute: StrainScorer.banisterLowBandPeakPerMinute
        )
        // 90 bpm is within 0.1 percentage points of the exact 20.5% HRR midpoint.
        XCTAssertEqual(trimp, 4.23, accuracy: 0.03)
        let denominator = StrainScorer.logMapDenominator(method: .banister, sex: "male")
        let historical21Scale = StrainScorer.trimpToStrain(trimp, denominator: denominator) * 21.0 / 100.0
        XCTAssertEqual(historical21Scale, 4.0, accuracy: 0.1)
    }

    /// The rate at exactly 30% HRR is the low-band peak; just above it the active curve
    /// adds only the Banister increase above the 30% anchor, with no step at the join.
    func testThirtyPercentBoundaryIsContinuous() {
        XCTAssertEqual(oneMinuteRate(94), 0.0094, accuracy: 1e-12)
        let x = 0.31
        let rawAtX = x * StrainScorer.banisterScale * exp(StrainScorer.banisterBMen * x)
        let rawAtAnchor = StrainScorer.banisterAnchorRatePerMinute(b: StrainScorer.banisterBMen)
        XCTAssertEqual(oneMinuteRate(95), 0.0094 + Swift.max(rawAtX - rawAtAnchor, 0), accuracy: 1e-12)
    }

    /// The active side is anchored at 30% HRR, not the former 22% sedentary threshold.
    func testAboveTheBandUsesThirtyPercentAnchorPlusPeak() {
        let x = 0.40
        let bpm = 104 // 40% HRR when reserve is 100 bpm
        let hr = [HRSample(ts: 0, bpm: bpm)]
        let rate = StrainScorer.banisterTRIMP(
            hr, restingHR: 64, hrReserve: 100, durations: [1.0],
            b: StrainScorer.banisterBMen,
            floorRatePerMinute: StrainScorer.banisterBaselineRatePerMinute(b: StrainScorer.banisterBMen),
            lowBandPeakPerMinute: StrainScorer.banisterLowBandPeakPerMinute
        )
        let expected = 0.0094 + Swift.max(
            x * StrainScorer.banisterScale * exp(StrainScorer.banisterBMen * x)
                - StrainScorer.banisterAnchorRatePerMinute(b: StrainScorer.banisterBMen),
            0
        )
        XCTAssertEqual(rate, expected, accuracy: 1e-12)
    }

    func testStrengthIntervalMultipliesOnlyItsBanisterSamplesByThirtyPercent() {
        let hr = [
            HRSample(ts: 100, bpm: 120),
            HRSample(ts: 160, bpm: 120),
            HRSample(ts: 220, bpm: 120),
        ]
        let durations = [1.0, 1.0, 1.0]
        let b = StrainScorer.banisterBMen
        let base = StrainScorer.banisterTRIMP(
            hr, restingHR: rest, hrReserve: max - rest, durations: durations, b: b,
            floorRatePerMinute: StrainScorer.banisterBaselineRatePerMinute(b: b),
            lowBandPeakPerMinute: StrainScorer.banisterLowBandPeakPerMinute)
        let weighted = StrainScorer.banisterTRIMP(
            hr, restingHR: rest, hrReserve: max - rest, durations: durations, b: b,
            floorRatePerMinute: StrainScorer.banisterBaselineRatePerMinute(b: b),
            lowBandPeakPerMinute: StrainScorer.banisterLowBandPeakPerMinute,
            strengthWorkoutIntervals: [.init(startTs: 100, endTs: 160)])
        let oneSample = StrainScorer.banisterTRIMP(
            [hr[0]], restingHR: rest, hrReserve: max - rest, durations: [1.0], b: b,
            floorRatePerMinute: StrainScorer.banisterBaselineRatePerMinute(b: b),
            lowBandPeakPerMinute: StrainScorer.banisterLowBandPeakPerMinute)
        XCTAssertEqual(weighted, base + oneSample * 0.30, accuracy: 1e-12)
    }

    func testOnlyStrengthTrainingAndPowerliftingQualify() {
        XCTAssertEqual(StrainScorer.strengthWorkoutMultiplier(for: "Strength Training"), 1.30)
        XCTAssertEqual(StrainScorer.strengthWorkoutMultiplier(for: "powerlifting"), 1.30)
        XCTAssertEqual(StrainScorer.strengthWorkoutMultiplier(for: "Running"), 1.0)
        XCTAssertEqual(StrainScorer.strengthWorkoutMultiplier(for: "Weightlifting"), 1.0)
    }

    /// With no low-band peak, the generic Banister path remains unchanged.
    func testDefaultPeakOfZeroLeavesTheOldRecipeAlone() {
        let hr = flat(95, minutes: 30)
        let d = hr.map { _ in 1.0 / 60.0 }
        let b = StrainScorer.banisterBMen
        let floor = StrainScorer.banisterBaselineRatePerMinute(b: b)
        let a = StrainScorer.banisterTRIMP(hr, restingHR: rest, hrReserve: max - rest, durations: d, b: b,
                                           floorRatePerMinute: floor)
        let z = StrainScorer.banisterTRIMP(hr, restingHR: rest, hrReserve: max - rest, durations: d, b: b,
                                           floorRatePerMinute: floor, lowBandPeakPerMinute: 0.0)
        XCTAssertEqual(a, z, accuracy: 1e-12)
    }

    /// The ordinary walking day combines the linear ramp and the anchored active curve.
    func testANormalWalkingDayUsesBothBands() throws {
        let hr = flat(90, minutes: 480) + (0 ..< 3600).map { HRSample(ts: 480 * 60 + $0, bpm: 105) }
        let s = try XCTUnwrap(StrainScorer.strain(hr, maxHR: max, restingHR: rest, method: .banister))
        XCTAssertEqual(s * 21.0 / 100.0, 4.5, accuracy: 0.2)
    }
}
