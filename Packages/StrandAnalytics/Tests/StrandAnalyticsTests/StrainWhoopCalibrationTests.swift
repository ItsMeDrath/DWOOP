import XCTest
@testable import StrandAnalytics

/// Regression coverage for the calibrated 30% HRR active-curve anchor.
/// The previous eight-day WHOOP screenshot fit targeted a 22% sedentary floor;
/// that calibration is intentionally superseded by the explicit 11–30% ramp.
final class StrainWhoopCalibrationTests: XCTestCase {

    func testActiveBanisterCurveUsesThirtyPercentAnchor() {
        XCTAssertEqual(StrainScorer.banisterAnchorHRR, 0.30, accuracy: 1e-12)
        XCTAssertEqual(StrainScorer.banisterLowBandEndHRR, StrainScorer.banisterAnchorHRR, accuracy: 1e-12)
    }

    func testBaselineOffsetMakesTheActiveCurveMeetTheRampPeak() {
        let b = StrainScorer.banisterBMen
        let rawAnchor = StrainScorer.banisterAnchorRatePerMinute(b: b)
        let offset = StrainScorer.banisterBaselineRatePerMinute(b: b)
        XCTAssertEqual(rawAnchor - offset, StrainScorer.banisterLowBandPeakPerMinute, accuracy: 1e-12)
    }
}
