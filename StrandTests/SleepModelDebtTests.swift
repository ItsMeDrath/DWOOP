import XCTest
import WhoopStore
@testable import Strand

final class SleepModelDebtTests: XCTestCase {
    private func day(_ value: String, sleep: Double?) -> DailyMetric {
        DailyMetric(day: value, totalSleepMin: sleep, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                    restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
                    exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
    }

    func testLocalFallbackLatestAgreesWithLedger() {
        let days = [day("2026-06-01", sleep: 360), day("2026-06-02", sleep: 480)]
        let metric = SleepModel.sleepDebtSeries(
            days: days, importedSleep: [:], napSleepMinByDay: [:])
        let ledger = SleepModel.debtLedger(days: days, napSleepMinByDay: [:])
        XCTAssertEqual(metric.latest ?? -1, ledger.magnitudeMin, accuracy: 1e-9)
    }

    #if os(iOS)
    func testWhoopStrainAddsThreeMinutesPerPointToSleepNeed() {
        // 5.3 WHOOP Strain is stored internally as 5.3 × (100 / 21) Effort.
        let internalEffort = 5.3 * (100.0 / 21.0)
        let result = NunaSleepNeedCalculation.calculate(
            sleep: [(day: "2026-06-02", mainMin: 450, napMin: 0)],
            strainByDay: ["2026-06-01": internalEffort])
        XCTAssertEqual(result["2026-06-02"]?.strainMin ?? -1, 5.3 * 3.0, accuracy: 1e-9)
    }

    func testMaximumWhoopStrainAddsSixtyThreeMinutes() {
        let result = NunaSleepNeedCalculation.calculate(
            sleep: [(day: "2026-06-02", mainMin: 450, napMin: 0)],
            strainByDay: ["2026-06-01": 100.0])
        XCTAssertEqual(result["2026-06-02"]?.strainMin ?? -1, 63.0, accuracy: 1e-9)
    }

    }
    #endif

    func testImportedWhoopDebtRemainsVerbatim() {
        let days = [day("2026-06-01", sleep: 480)]
        let imported = ["2026-06-01": ImportedSleepFigures(
            performancePct: nil, consistencyPct: nil, needMin: nil, debtMin: 17.25)]
        let metric = SleepModel.sleepDebtSeries(
            days: days, importedSleep: imported, napSleepMinByDay: [:])
        XCTAssertEqual(metric.latest ?? -1, 17.25, accuracy: 1e-9)
    }
}
