import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// Covers the two small AI-Coach additions:
///   1. The editable system prompt — persisted in UserDefaults under `AICoachEngine.systemPromptKey`,
///      read FRESH per request via `systemPrompt`, with a Reset-to-default that clears the override.
///   2. The derived Baevsky Stress Index context line — its pure formatter (`stressIndexSummary`) and
///      that the line uses the SAME `StressIndex.stressIndex(rr:)` computation StressView does.
///
/// Both paths are UserDefaults / pure — no network, no Keychain — so they run headlessly.
@MainActor
final class AICoachPromptAndStressTests: XCTestCase {

    /// A fresh engine plus a clean slate: clear the prompt key before and after so tests don't leak.
    private func makeEngine() -> AICoachEngine {
        UserDefaults.standard.removeObject(forKey: AICoachEngine.systemPromptKey)
        return AICoachEngine(repo: Repository(deviceId: "test-aicoach-prompt"))
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AICoachEngine.systemPromptKey)
        super.tearDown()
    }

    // MARK: - Feature 1: editable system prompt

    func testDefaultsToBuiltInPromptWhenNothingStored() {
        let engine = makeEngine()
        XCTAssertEqual(engine.systemPrompt, AICoachEngine.defaultSystemPrompt)
        XCTAssertFalse(engine.hasCustomSystemPrompt)
    }

    func testEditPersistsAndIsReadFreshOnNextSend() {
        let engine = makeEngine()
        let custom = "You are a terse cycling coach. Answer in two sentences."
        engine.customSystemPrompt = custom

        // Persisted under the documented key, and surfaced by the fresh-read property.
        XCTAssertEqual(UserDefaults.standard.string(forKey: AICoachEngine.systemPromptKey), custom)
        XCTAssertEqual(engine.systemPrompt, custom)
        XCTAssertTrue(engine.hasCustomSystemPrompt)

        // "Read fresh per send" — a write straight to UserDefaults (as another session might) is
        // picked up by the next `systemPrompt` read without rebuilding the engine.
        let edited = custom + " Always cite a number."
        UserDefaults.standard.set(edited, forKey: AICoachEngine.systemPromptKey)
        XCTAssertEqual(engine.systemPrompt, edited)
    }

    func testResetRestoresDefaultAndClearsTheKey() {
        let engine = makeEngine()
        engine.customSystemPrompt = "Custom override."
        XCTAssertTrue(engine.hasCustomSystemPrompt)

        engine.resetSystemPrompt()
        XCTAssertNil(UserDefaults.standard.string(forKey: AICoachEngine.systemPromptKey))
        XCTAssertEqual(engine.systemPrompt, AICoachEngine.defaultSystemPrompt)
        XCTAssertFalse(engine.hasCustomSystemPrompt)
    }

    func testBlankOverrideNeverSendsAnEmptyPrompt() {
        let engine = makeEngine()
        engine.customSystemPrompt = "   \n  "   // whitespace only
        // A blank override clears the key, so the default is sent — never an empty system prompt.
        XCTAssertNil(UserDefaults.standard.string(forKey: AICoachEngine.systemPromptKey))
        XCTAssertEqual(engine.systemPrompt, AICoachEngine.defaultSystemPrompt)
        XCTAssertFalse(engine.hasCustomSystemPrompt)
    }

    func testBuiltInPromptPrioritizesConciseActionableReplies() {
        let prompt = AICoachEngine.defaultSystemPrompt
        XCTAssertTrue(prompt.contains("Answer the user's question first"))
        XCTAssertTrue(prompt.contains("under 120 words"))
        XCTAssertTrue(prompt.contains("2-3 concrete actions"))
        XCTAssertTrue(prompt.contains("Do not use tables"))
        XCTAssertTrue(prompt.contains("Talk like a perceptive human coach"))
        XCTAssertTrue(prompt.contains("First form a body-state read from the pattern"))
    }

    // MARK: - Feature 3: body-state synthesis

    func testBodyStateConnectsSleepAndAutonomicSignalsToAction() {
        let days = [
            metric(day: "2026-09-01", sleep: 450, hrv: 65, rhr: 52, charge: 72, effort: 10),
            metric(day: "2026-09-02", sleep: 440, hrv: 64, rhr: 52, charge: 70, effort: 11),
            metric(day: "2026-09-03", sleep: 330, hrv: 48, rhr: 57, charge: 68, effort: 12),
        ]

        let summary = AICoachEngine.bodyStateSummary(current: days[2], history: days)

        XCTAssertTrue(summary.contains("under-recovered despite the Recovery score"), summary)
        XCTAssertTrue(summary.contains("sleep 5.5h"), summary)
        XCTAssertTrue(summary.contains("HRV 48ms"), summary)
        XCTAssertTrue(summary.contains("RHR 57bpm"), summary)
        XCTAssertTrue(summary.contains("Keep intensity controlled"), summary)
    }

    func testBodyStateDoesNotInventAConclusionFromSparseData() {
        let current = metric(day: "2026-09-03", sleep: nil, hrv: nil, rhr: nil, charge: nil, effort: 4)
        let summary = AICoachEngine.bodyStateSummary(current: current, history: [current])

        XCTAssertTrue(summary.contains("steady but not a clear green light"), summary)
        XCTAssertTrue(summary.contains("Confidence limited"), summary)
        XCTAssertTrue(summary.contains("recent strain 0.8"), summary)
    }

    private func metric(day: String, sleep: Double?, hrv: Double?, rhr: Int?, charge: Double?, effort: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv,
                    recovery: charge, strain: effort, exerciseCount: nil)
    }

    // MARK: - WHOOP-native scores

    func testDailyContextLineMatchesWHOOPStrainDisplay() {
        let engine = makeEngine()
        let row = metric(day: "2026-09-04", sleep: 450, hrv: 65, rhr: 52, charge: 72, effort: 50)
        XCTAssertTrue(engine.dayLine(row).contains("Strain 10.5"), engine.dayLine(row))
        XCTAssertFalse(engine.dayLine(row).contains("Strain 50.0"), engine.dayLine(row))
    }

    func testCoachUsesWHOOPStrainScaleRatherThanInternalHundredScale() {
        XCTAssertEqual(AICoachEngine.whoopStrain(100), 21, accuracy: 1e-9)
        XCTAssertEqual(AICoachEngine.whoopStrain(50), 10.5, accuracy: 1e-9)
        XCTAssertEqual(AICoachEngine.whoopStrain(12.3), 2.583, accuracy: 1e-9)
        XCTAssertEqual(AICoachEngine.whoopStrain(-5), 0, accuracy: 1e-9)
        XCTAssertEqual(AICoachEngine.whoopStrain(120), 21, accuracy: 1e-9)
    }

    func testStressSummaryUsesWHOOPZeroToThreeScaleAndNotBaevsky() {
        let line = AICoachEngine.whoopStressSummary(level: 2.36)
        XCTAssertEqual(line, "WHOOP Stress Monitor (0–3): 2.4")
        XCTAssertFalse(line.contains("Baevsky"))
        XCTAssertFalse(line.contains("SI"))
    }

    func testDefaultPromptDefinesOnlyWHOOPScoreScales() {
        let prompt = AICoachEngine.defaultSystemPrompt
        XCTAssertTrue(prompt.contains("Recovery 0-100"))
        XCTAssertTrue(prompt.contains("Strain 0-21"))
        XCTAssertTrue(prompt.contains("Stress Monitor 0-3"))
        XCTAssertFalse(prompt.contains("effort 0-100"))
        XCTAssertFalse(prompt.contains("charge 0-100"))
        XCTAssertFalse(prompt.contains("Baevsky"))
    }

}
