#if os(iOS)
import Foundation
import StrandAnalytics
import WhoopProtocol

/// Minutes in each of the five heart-rate zones, read from the stored heart-rate samples. One reader for the HR zones pages and the plan, so the
/// time one of them states is the time the other states.
enum NunaZoneMinutes {
    /// One rolling 30-day average RHR baseline is used for every displayed HR zone.
    @MainActor private static func baseline(repo: Repository, age: Int) -> (maxHR: Double, restingHR: Double, custom: [Double]?) {
        let override = UserDefaults.standard.integer(forKey: "profile.hrMaxOverride")
        let maxHR = override > 0 ? Double(override)
            : (age > 0 ? StrainScorer.tanakaHRmax(age: Double(age)) : Double(StrainScorer.defaultMaxHR()))
        let cutoff = Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
        let cutoffKey = Repository.localDayKey(cutoff)
        let values = repo.days.filter { $0.day >= cutoffKey }.compactMap { $0.restingHr.map(Double.init) }
        let resting = values.isEmpty ? StrainScorer.defaultRestingHR : values.reduce(0, +) / Double(values.count)
        let stored = UserDefaults.standard.string(forKey: "profile.hrZoneThresholds")?
            .split(separator: ",").compactMap { Double($0) }
        let custom = stored.flatMap(HRZones.validCustomLowerBounds)
        return (maxHR, resting, custom)
    }

    /// Every day's five zone totals, all against the same rolling 30-day RHR baseline.
    @MainActor static func perDay(repo: Repository, age: Int, days: [Date]) async -> [Date: [Double]] {
        let (maxHR, restingHR, custom) = baseline(repo: repo, age: age)
        var result: [Date: [Double]] = [:]
        let calendar = Calendar.current
        for day in days {
            let start = calendar.startOfDay(for: day)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            let samples = await repo.hrSamples(from: Int(start.timeIntervalSince1970),
                                               to: Int(end.timeIntervalSince1970), limit: 50_000)
            result[day] = HRZones.timeInZone(samples,
                zoneSet: .whoopBands(maxHR: maxHR, restingHR: restingHR, customLowerBounds: custom)).seconds.map { $0 / 60 }
        }
        return result
    }

    /// The five zone totals inside one window, against the same rolling 30-day resting-HR baseline.
    @MainActor static func inWindow(repo: Repository, age: Int, from: Int, to: Int, day: Date) async -> [Double] {
        let (maxHR, restingHR, custom) = baseline(repo: repo, age: age)
        let samples = await repo.hrSamples(from: from, to: to, limit: 50_000)
        return HRZones.timeInZone(samples,
            zoneSet: .whoopBands(maxHR: maxHR, restingHR: restingHR, customLowerBounds: custom)).seconds.map { $0 / 60 }
    }
}
#endif
