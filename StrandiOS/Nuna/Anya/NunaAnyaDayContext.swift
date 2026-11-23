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

        // Need and debt use the Sleep tab's own functions, main sleep only (naps are not credited here).
        let need = SleepModel.debtNeedMin(days: days)
        let ledger = SleepDebt.ledger(series: days.map { (day: $0.day, totalSleepMin: $0.totalSleepMin) }, needHours: need / 60)
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
            sleepNeedMin: ledger.nightCount > 0 ? need : nil,
            sleepDebtMin: ledger.nightCount > 0 ? ledger.magnitudeMin : nil,
            habitualMidsleepSec: midsleep,
            sessionFeelings: feelings,
            outdoorLine: outdoor?.line,
            outdoorLevel: outdoor?.level)
        var context = AnyaDayContext.block(input)

        // The same weekly Body Age / WHOOP Healthspan-style result and factor breakdown shown
        // on the Health tab. NunaHealthspan shares the Healthspan screen's cached reader/model,
        // so Coach never recomputes a different age or invents contributors.
        if let age = await NunaHealthspan.latest(repo: repo, profile: profile),
           let bodyAge = age.bodyAge {
            context += "\n\n" + bodyAgeContext(age)
        }
        return context
    }

    /// Compact explanation of the exact weekly Body Age and signed factor effects.
    /// Positive years make the estimate older; negative years make it younger.
    static func bodyAgeContext(_ result: NunaHealthspanResult) -> String {
        guard let bodyAge = result.bodyAge else {
            return "BODY AGE: Not available yet; do not estimate it."
        }
        let chronological = result.inputs.chronoAge
        let difference = bodyAge - chronological
        let comparison: String
        if abs(difference) < 0.5 {
            comparison = "about the same as chronological age"
        } else if difference < 0 {
            comparison = String(format: "%.1f years younger than chronological age", abs(difference))
        } else {
            comparison = String(format: "%.1f years older than chronological age", difference)
        }
        let ageLine = String(format: "Body Age %.1f years; chronological age %.0f; %@", bodyAge, chronological, comparison)
        let factors = result.contributions.map { contribution -> String in
            let years = VitalityEngine.years(of: contribution)
            let sign = years > 0 ? "+" : ""
            let direction = years > 0.05 ? "adds age" : (years < -0.05 ? "lowers age" : "near neutral")
            return String(format: "%@: %@%.1f years (%@)", contribution.label, sign, years, direction)
        }
        let factorLine = factors.isEmpty ? "No individual factors are available yet." : factors.joined(separator: "; ")
        return """
        BODY AGE / WHOOP HEALTHSPAN-STYLE ESTIMATE (weekly, same result and inputs as the Health tab):
        \(ageLine). Based on \(result.inputsUsed) available factors. Factor effects are signed contributions: positive adds years, negative takes years off. \(factorLine)
        This is the app's wellness estimate, not a clinical or medical age. Use the listed factors to explain what is helping or holding it back; never infer missing factors.
        """
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
