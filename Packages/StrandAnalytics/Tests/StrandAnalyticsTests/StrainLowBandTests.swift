import XCTest
import Foundation
@testable import StrandAnalytics
import WhoopProtocol

/// The Banister low band: heart rate between 11% and 30% of reserve (about 78 to 102 bpm at resting 64 / max 191)
/// earns a small linear ramp instead of the sedentary-floor excess; at and above 30% the score is the plain
/// Banister excess over `banisterSedentaryHRR`, as before.
final class StrainLowBandTests: XCTestCase {

    private let rest = 64.0, max = 191.0

    private func flat(_ bpm: Int, minutes: Int) -> [HRSample] {
        (0 ..< minutes * 60).map { HRSample(ts: $0, bpm: bpm) }
    }

    func testTheBandBoundsAreSharesOfReserve() {
        XCTAssertEqual(StrainScorer.banisterLowBandStartHRR, 0.11, accuracy: 1e-12)
        XCTAssertEqual(StrainScorer.banisterLowBandEndHRR, 0.30, accuracy: 1e-12)
        XCTAssertEqual(StrainScorer.banisterLowBandPeakPerMinute, 0.02, accuracy: 1e-12)
    }

    /// Below the band's start nothing is earned, however long it lasts (sleep at 60 to 75 bpm).
    func testBelowTheBandEarnsNothing() {
        XCTAssertEqual(StrainScorer.strain(flat(70, minutes: 600), maxHR: max, restingHR: rest, method: .banister), 0.0)
    }

    /// 8 hours at 90 bpm sits about halfway up the ramp: about 4.8 TRIMP, which is about 20 on the 0-100 axis
    /// (4.2 of 21).
    func testEightHoursInTheBandIsAboutFourOnTheWhoopScale() throws {
        let s = try XCTUnwrap(StrainScorer.strain(flat(90, minutes: 480), maxHR: max, restingHR: rest, method: .banister))
        XCTAssertEqual(s, 20.2, accuracy: 0.6)
    }

    /// From the band's end up the curve is the plain floored Banister, so a sample at 120 bpm scores the same
    /// with the band on or off.
    func testAboveTheBandTheCurveIsUnchanged() {
        let hr = flat(120, minutes: 30)
        let d = hr.map { _ in 1.0 / 60.0 }
        let b = StrainScorer.banisterBMen
        let floor = StrainScorer.banisterBaselineRatePerMinute(b: b)
        let off = StrainScorer.banisterTRIMP(hr, restingHR: rest, hrReserve: max - rest, durations: d, b: b,
                                             floorRatePerMinute: floor)
        let on = StrainScorer.banisterTRIMP(hr, restingHR: rest, hrReserve: max - rest, durations: d, b: b,
                                            floorRatePerMinute: floor,
                                            lowBandPeakPerMinute: StrainScorer.banisterLowBandPeakPerMinute)
        XCTAssertEqual(on, off, accuracy: 1e-9)
    }

    /// With the peak left at its default of zero, behaviour is byte-identical to before (every other caller).
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

    /// The ordinary lazy day: 8 h in the band plus an hour at 105 reads about 6.7 of 21, i.e. about 32 of 100.
    func testANormalWalkingDayLandsNearSix() throws {
        let hr = flat(90, minutes: 480) + (0 ..< 3600).map { HRSample(ts: 480 * 60 + $0, bpm: 105) }
        let s = try XCTUnwrap(StrainScorer.strain(hr, maxHR: max, restingHR: rest, method: .banister))
        XCTAssertEqual(s * 21.0 / 100.0, 6.7, accuracy: 0.6)
    }
}
