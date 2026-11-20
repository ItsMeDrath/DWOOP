import XCTest
@testable import StrandAnalytics

/// Recovery's sleep input: hours vs needed 60, consistency 20 (full at 90%), efficiency 10 (full at 90%), restorative sleep 10 (full at 50% of the night).
final class RestRecoveryInputTests: XCTestCase {
    private let night = 8.0 * 3600.0

    private func input(tst: Double = 8.0 * 3600.0, eff: Double = 0.95, restShare: Double = 0.5, deepShare: Double = 0.2,
                       need: Double = 8.0, consistency: Double? = 0.95) -> Double {
        AnalyticsEngine.Rest.recoveryInput(tstSeconds: tst, efficiency: eff, restorativeSeconds: tst * restShare,
                                           needHours: need, consistency: consistency, deepSeconds: tst * deepShare)
    }

    func testFullNightScoresOneHundred() {
        XCTAssertEqual(input(), 100, accuracy: 0.01)
    }

    func testHalfTheRestorativeTargetLosesFivePoints() {
        XCTAssertEqual(input(restShare: 0.25), 95, accuracy: 0.01)
    }

    func testEfficiencyAndConsistencyAreFullAtNinetyAndNoHigher() {
        XCTAssertEqual(input(eff: 0.90, consistency: 0.90), 100, accuracy: 0.01)
        XCTAssertEqual(input(eff: 1.0, consistency: 1.0), 100, accuracy: 0.01)
        // 45% efficiency is half of the 10 points.
        XCTAssertEqual(input(eff: 0.45), 95, accuracy: 0.01)
    }

    func testUnknownConsistencyEarnsHalfOfItsTwentyPoints() {
        XCTAssertEqual(input(consistency: nil), 90, accuracy: 0.01)
    }

    func testHoursAreSixtyPoints() {
        XCTAssertEqual(input(tst: night / 2), 70, accuracy: 0.01)
    }

    func testNoDeepSleepHalvesTheRestorativeTerm() {
        XCTAssertEqual(input(deepShare: 0), 95, accuracy: 0.01)
    }
}
