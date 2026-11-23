#if os(iOS)
import Foundation
import StrandAnalytics
import WhoopStore

/// Gathers the numbers for `AnyaDayContext` on this iPhone. The session is the one `NunaDayPlanResult` returns, so Anya and the
/// Plan card read the same plan from one function and cannot disagree about it.
enum NunaAnyaDayContext {

    /// Gives Anya the day's context with every request and the daily brief, and a fresh weather and air reading before the brief.
    @MainActor static func install(on coach: AICoachEngine, repo: Repository, profile: ProfileStore) {
        coach.dayContextProvider = { await build(repo: repo, profile: profile) }
        coach.beforeBrief = { await EnvironmentStore.shared.refreshIfNeeded() }
    }

    @MainActor static func build(repo: Repository, profile: ProfileStore, now: Date = Date()) async -> String {
        let days = repo.days
        let plan = await NunaDayPlanResult.load(repo: repo, profile: profile)
        let scored = days.compactMap(\.strain).filter { $0 > 0 }.suffix(30).sorted()
        let usual = scored.isEmpty ? nil : scored[scored.count / 2]
        let todayKey = repo.today?.day ?? Repository.localDayKey(now)
        let today = days.last(where: { $0.day == todayKey })?.strain
        let week = days.suffix(7).compactMap(\.strain).reduce(0, +)
        let goal = UserDefaults.standard.double(forKey: "nuna.goal.weeklyEffort")

        // Use the same per-night calculation as the Sleep screen's Need and debt card.
        // That card uses NunaSleepNeedCalculation (including nap sleep and daily Strain),
        // not the separate historical SleepDebt ledger.
        let sleepModel = NunaSleepModel.shared
        await sleepModel.load(repo: repo, historyDays: 60, includeMotion: false)
        let latestNight = sleepModel.nights.first
        let midsleep = await repo.habitualMidsleepSec()

        // The wearer's own rating of the last sessions, from the same store the review screen writes.
        let rows = await repo.workoutRows(days: 14)
        let feelings = rows.prefix(6).compactMap { r -> String? in
            guard let f = NunaWorkoutReviewStore.load(startTs: r.startTs, sport: r.sport).feelingValue else { return nil }
            return "\(r.sport), \(f.plain)"
        }

        // The weather and air, when they are on and were read in the last three hours; a fresh read is started for next time.
        let env = EnvironmentStore.shared
        var outdoor: (line: String, level: String)?
        if env.isActive {
            Task { await env.refreshIfNeeded() }
            if let snap = env.snapshot, now.timeIntervalSince1970 - Double(snap.ts) < 3 * 3600, let advice = EnvironmentAdvice.analyze(snap) {
                outdoor = (Self.outdoorLine(snap, advice), advice.level == .good ? "good" : (advice.level == .adjust ? "adjust" : "indoors"))
            }
        }

        // The band the Today card judges the day by: Charge sets how much Effort is worth aiming for.
        let band = CoupledView.optimalStrainRange(recovery: plan.map { Double($0.charge) })
        let input = AnyaDayContext.Input(
            now: now,
            chargePct: plan.map { Double($0.charge) },
            sessionTitle: plan?.title,
            sessionKind: plan?.plan.kind.rawValue,
            sessionMainZone: plan?.plan.mainZone,
            sessionEffortLow: plan?.plan.effortLow,
            sessionEffortHigh: plan?.plan.effortHigh,
            todayEffort: today,
            effortTargetLow: band.map { Double($0.lowerBound) / UnitFormatter.effortScaleFactor },
            effortTargetHigh: band.map { Double($0.upperBound) / UnitFormatter.effortScaleFactor },
            usualEffort: usual,
            weekEffort: week > 0 ? week : nil,
            weeklyEffortGoal: goal > 0 ? goal : nil,
            sleepNeedMin: latestNight.map { sleepModel.need($0) },
            sleepBaselineMin: NunaSleepNeedCalculation.healthyMin,
            sleepStrainAdjustmentMin: latestNight.map { sleepModel.strain($0) },
            sleepDebtMin: latestNight.map { sleepModel.debt($0) },
            habitualMidsleepSec: midsleep,
            sessionFeelings: feelings,
            outdoorLine: outdoor?.line,
            outdoorLevel: outdoor?.level)
        // Pass the same sleep scores and components already loaded above.
        let sleepContext = Self.sleepPerformanceBlock(model: sleepModel)

        // Use the exact same cached seven-day calculation as the WHOOP Age orb and detail page.
        // The factor contributions below come from the same VitalityEngine inputs, not a second estimate.
        let whoopAgeContext: String
        if let healthspan = await NunaHealthspan.latest(repo: repo, profile: profile) {
            whoopAgeContext = Self.whoopAgeContext(healthspan)
        } else {
            whoopAgeContext = "WHOOP AGE: Not available yet. The Health tab needs chronological age in the profile and at least 3 of its 9 weekly inputs. Do not estimate or invent an age."
        }
        return [AnyaDayContext.block(input), sleepContext, whoopAgeContext]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Same WHOOP Age value and nine signed factor effects as the Health tab's factor breakdown.
    /// Positive years add to the estimate; negative years reduce it.
    static func whoopAgeContext(_ result: NunaHealthspanResult) -> String {
        let inputs = result.inputs
        let ageLine: String
        if let age = result.bodyAge {
            // The orb displays WHOOP Age as a whole number (NunaFitnessOrbCenter, %.0f).
            let displayedAge = Int(age.rounded())
            let difference = Int((inputs.chronoAge - age).rounded())
            let relation = difference == 0 ? "about the same as chronological age"
                : difference > 0 ? "\(difference) years younger than chronological age"
                : "\(abs(difference)) years older than chronological age"
            ageLine = "WHOOP Age \(displayedAge) years; chronological age \(Int(inputs.chronoAge.rounded())); \(relation)"
        } else {
            ageLine = "WHOOP Age is not available yet; at least 3 of the 9 factors are needed"
        }

        func duration(_ minutes: Double) -> String {
            let total = Int(minutes.rounded())
            return "\(total / 60)h \(total % 60)m"
        }
        func factor(_ title: String, value: Double?, key: String, format: (Double) -> String) -> String {
            guard let value else { return "\(title): unavailable (not counted)" }
            guard let years = result.years(key) else { return "\(title): \(format(value)); contribution unavailable" }
            let effect = years > 0.05 ? "adds to age" : (years < -0.05 ? "reduces age" : "near neutral")
            return "\(title): \(format(value)); \(String(format: "%+.1f", years)) years (\(effect))"
        }

        let factors = [
            factor("Sleep consistency", value: inputs.sleepConsistency, key: "consistency") { String(format: "%.0f%%", $0 * 100) },
            factor("Average sleep", value: inputs.sleepHours, key: "sleep") { duration($0 * 60) },
            factor("HR zones 1–3 per week", value: inputs.zonesLowMin, key: "zonesLow", format: duration),
            factor("HR zones 4–5 per week", value: inputs.zonesHighMin, key: "zonesHigh", format: duration),
            factor("Strength activity per week", value: inputs.strengthMin, key: "strength", format: duration),
            factor("Daily steps average", value: inputs.steps, key: "steps") { Int($0.rounded()).formatted() },
            factor("VO₂ max", value: inputs.vo2max, key: "vo2max") { String(format: "%.1f ml/kg/min", $0) },
            factor("Resting heart rate", value: inputs.restingHR, key: "rhr") { String(format: "%.1f bpm", $0) },
            factor("Lean body mass", value: inputs.leanMassPct, key: "leanMass") { String(format: "%.1f%%", $0) }
        ]
        return """
        WHOOP AGE (same seven-day value shown in the Health tab):
        \(ageLine). \(result.inputsUsed) of 9 factors currently have data.
        Factor contributions (positive years add to WHOOP Age; negative years reduce it):
        \(factors.map { "• " + $0 }.joined(separator: "\n"))
        This is the app's wellness estimate, not a biological age or medical assessment. Stress Monitor itself is not one of the nine direct WHOOP Age inputs; use the factor effects above to explain what changes the estimate.
        """
    }

    /// Uses the same per-night score and components as the iOS Sleep ring.
    @MainActor private static func sleepPerformanceBlock(model: NunaSleepModel) -> String {
        let recent = Array(model.nights.prefix(14))
        let scores = Array(model.nights.prefix(30)).compactMap { model.sleepScore($0) }
        guard !recent.isEmpty else { return "" }
        let average = scores.isEmpty ? "—" : "\(Int((scores.reduce(0, +) / Double(scores.count)).rounded()))%"
        func pct(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "unavailable" }
        func stressPct(_ value: Double?) -> String { value.map { "\(Int(max(0, $0)))%" } ?? "unavailable" }
        var lines = ["SLEEP PERFORMANCE (same iOS 60/20/10/10 score as the Sleep ring):",
                     "30-night average: \(average) (\(scores.count) nights with a calculable score).",
                     "Recent nights (newest first):"]
        for night in recent {
            let score = model.sleepScore(night).map { "\(Int($0.rounded()))%" } ?? "unavailable"
            lines.append("  \(night.dayKey): score \(score); hours vs needed \(pct(model.hoursVsNeeded(night))); consistency \(pct(model.consistency(night))); efficiency \(pct(model.efficiency(night))); high sleep stress \(stressPct(model.sleepStressHighPct[night.dayKey])).")
        }
        lines.append("Weights: hours vs needed 60%, five-night consistency 20%, efficiency 10%, low sleep stress 10%; restorative sleep is display-only and contributes 0%.")
        return lines.joined(separator: "\n")
    }

    /// The reading and what it means for training, in plain English for Anya.
    static func outdoorLine(_ s: EnvironmentSnapshot, _ a: EnvironmentAdvice) -> String {
        func c(_ v: Double) -> String { "\(Int(v.rounded())) degrees C" }
        var parts: [String] = []
        if let p = s.place { parts.append(p + ":") }
        var weather: [String] = []
        if let t = s.tempC { weather.append(c(t)) }
        if let f = s.feelsLikeC { weather.append("feels like \(c(f))") }
        if let h = s.humidityPct { weather.append("humidity \(Int(h.rounded()))%") }
        if let w = s.windMps { weather.append("wind \(Int(w.rounded())) m/s") }
        if let t = s.conditionText { weather.append(t) }
        if !weather.isEmpty { parts.append(weather.joined(separator: ", ") + ".") }
        if let aqi = s.usAqi { parts.append("Air quality US AQI \(aqi) (\(AirQuality.band(usAqi: aqi)))" + (s.pm25.map { ", PM2.5 \(Int($0.rounded())) ug/m3" } ?? "") + ".") }
        let level = a.level == .good ? "good" : (a.level == .adjust ? "adjust: go shorter and easier" : "indoors: better to train inside today")
        parts.append("Training conditions: \(level).")
        var why: [String] = []
        for r in a.reasons {
            switch r {
            case .veryHot(let t): why.append("very hot, feels like \(c(t))")
            case .hot(let t): why.append("hot, feels like \(c(t))")
            case .cold(let t): why.append("cold, feels like \(c(t))")
            case .freezing(let t): why.append("freezing, feels like \(c(t))")
            case .air(let aqi, _): why.append("air quality \(aqi)")
            case .storm: why.append("thunderstorm")
            case .rain: why.append("rain")
            case .wind(let m): why.append("strong wind \(Int(m.rounded())) m/s")
            }
        }
        if !why.isEmpty { parts.append("Because: " + why.joined(separator: "; ") + ".") }
        if let k = a.cooler {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            parts.append("It should feel like \(c(k.feelsLikeC)) around \(f.string(from: Date(timeIntervalSince1970: TimeInterval(k.ts)))), a kinder time to go.")
        }
        return parts.joined(separator: " ")
    }
}
#endif
