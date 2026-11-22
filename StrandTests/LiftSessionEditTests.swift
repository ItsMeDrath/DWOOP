import XCTest
@testable import Strand
import WhoopStore

/// Correcting a finished session. The parsing is the part that can quietly store the wrong number.
@MainActor
final class LiftSessionEditTests: XCTestCase {

    private func row(weightKg: Double? = 60, reps: Int? = 8, rpe: Double? = nil) -> LiftSetRow {
        LiftSetRow(id: "s1", deviceId: "d", sessionId: "x", ord: 0, exercise: "Squat",
                   primaryMuscle: .quads, setIndex: 1, weightKg: weightKg, reps: reps, rpe: rpe,
                   isWarmup: false, startTs: 100, endTs: 140, restSec: 90, note: nil)
    }

    /// Opening and saving an untouched pound value must not nudge the stored kilograms.
    func testAnUntouchedFieldIsNotWrittenBack() {
        let before = LiftSessionEditSheet.form(for: row(), system: .imperial)
        var after = before
        after.reps = "10"
        let edited = LiftSessionEditSheet.applying(after, over: before, to: row(), system: .imperial)
        XCTAssertEqual(edited.weightKg, 60, "exactly the stored kilograms, not a round trip through pounds")
        XCTAssertEqual(edited.reps, 10)
    }

    func testAChangedWeightIsReadInTheDisplayUnit() {
        let before = LiftSessionEditSheet.form(for: row(), system: .imperial)
        var after = before
        after.weight = "135"
        let edited = LiftSessionEditSheet.applying(after, over: before, to: row(), system: .imperial)
        XCTAssertEqual(edited.weightKg ?? 0, LiftFormat.kilograms(fromDisplay: 135, system: .imperial),
                       accuracy: 1e-9)
    }

    func testADecimalCommaAndAClearedFieldAreHonoured() {
        let before = LiftSessionEditSheet.form(for: row(rpe: 8), system: .metric)
        var after = before
        after.weight = "62,5"
        after.rpe = ""
        let edited = LiftSessionEditSheet.applying(after, over: before, to: row(rpe: 8), system: .metric)
        XCTAssertEqual(edited.weightKg, 62.5)
        XCTAssertNil(edited.rpe, "a cleared field clears the value rather than keeping the old one")
    }

    func testMarkingAWarmUpAfterTheFactApplies() {
        let before = LiftSessionEditSheet.form(for: row(), system: .metric)
        var after = before
        after.isWarmup = true
        XCTAssertTrue(LiftSessionEditSheet.applying(after, over: before, to: row(), system: .metric).isWarmup)
    }

    // MARK: Sets and exercises added to a finished session

    private let session = LiftSessionRow(id: "x", deviceId: "d", startTs: 100, endTs: 4000, sport: "Strength Trainer",
                                         programId: nil, programName: nil, sessionRpe: nil, note: nil)

    private func newSet(_ exercise: String, weight: String, reps: String, warmup: Bool = false,
                        primary: LiftMuscle? = .quads) -> LiftSessionEditSheet.NewSet {
        var n = LiftSessionEditSheet.NewSet(seed: .init(exercise: exercise, primaryMuscle: primary))
        n.form = .init(weight: weight, reps: reps, rpe: "", isWarmup: warmup)
        return n
    }

    /// A new set joins its exercise after the last logged set, and goes after every set of the session.
    func testANewSetTakesTheNextNumberAndTheLastPlace() {
        let rows = LiftSessionEditSheet.newRows(from: [newSet("Squat", weight: "70", reps: "5")],
                                                session: session, after: [row()], system: .metric)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].setIndex, 2)
        XCTAssertEqual(rows[0].ord, 1)
        XCTAssertEqual(rows[0].sessionId, "x")
        XCTAssertEqual(rows[0].weightKg, 70)
        XCTAssertEqual(rows[0].reps, 5)
        XCTAssertNil(rows[0].startTs, "an added set has no times of its own")
        XCTAssertNotEqual(rows[0].id, "s1")
    }

    func testANewExerciseStartsAtSetOneAndSeveralSetsCount() {
        let rows = LiftSessionEditSheet.newRows(
            from: [newSet("Row", weight: "50", reps: "10", primary: .lats), newSet("Row", weight: "55", reps: "8", primary: .lats)],
            session: session, after: [row()], system: .metric)
        XCTAssertEqual(rows.map(\.setIndex), [1, 2])
        XCTAssertEqual(rows.map(\.ord), [1, 2])
        XCTAssertEqual(rows.first?.primaryMuscle, .lats)
    }

    /// A row left with no weight and no reps is not a set, and a weight is read in the display unit.
    func testABlankNewSetIsLeftOutAndPoundsAreConverted() {
        let rows = LiftSessionEditSheet.newRows(
            from: [newSet("Squat", weight: "", reps: ""), newSet("Squat", weight: "135", reps: "5", warmup: true)],
            session: session, after: [row()], system: .imperial)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isWarmup)
        XCTAssertEqual(rows[0].weightKg ?? 0, LiftFormat.kilograms(fromDisplay: 135, system: .imperial), accuracy: 1e-9)
    }
}
