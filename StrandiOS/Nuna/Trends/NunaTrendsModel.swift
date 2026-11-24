#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The daily series every Trends screen reads, loaded once from the repository, with helpers to cut a trailing window
/// and the window before it. Nothing is filled in: a day without a reading is simply not in the array.
@MainActor
final class NunaTrendsModel: ObservableObject {
    typealias Series = [(day: String, value: Double)]

    @Published private(set) var charge: Series = []
    @Published private(set) var effort: Series = []     // stored 0-100 axis
    @Published private(set) var rest: Series = []
    @Published private(set) var hrv: Series = []
    @Published private(set) var rhr: Series = []
    @Published private(set) var stress: Series = []
    @Published private(set) var steps: Series = []
    @Published private(set) var loaded = false

    let todayKey = Repository.localDayKey(Date())

    func load(repo: Repository) async {
        // Seed Sleep from the same persisted nightly scores as the Sleep circle; the 400-day
        // validation below replaces these optimistic values when its current inputs are ready.
        let cachedSleepScores = NunaSleepModel.cachedSleepScores()
        if !cachedSleepScores.isEmpty {
            rest = cachedSleepScores.map { (day: $0.key, value: $0.value) }.sorted { $0.day < $1.day }
        }
        async let c = repo.exploreSeries(key: "recovery", source: "my-whoop", days: 400)
        async let e = repo.exploreSeries(key: "strain", source: "my-whoop", days: 400)
        async let r = repo.exploreSeries(key: "sleep_performance", source: "my-whoop", days: 400)
        async let h = repo.exploreSeries(key: "hrv", source: "my-whoop", days: 400)
        async let k = repo.exploreSeries(key: "rhr", source: "my-whoop", days: 400)
        async let t = repo.exploreSeries(key: "steps_est", source: "my-whoop", days: 400)
        charge = Self.clean(await c); effort = Self.clean(await e); rest = Self.clean(await r)
        if !cachedSleepScores.isEmpty {
            var byDay = Dictionary(rest.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            for (day, score) in cachedSleepScores { byDay[day] = score }
            rest = byDay.map { (day: $0.key, value: $0.value) }.sorted { $0.day < $1.day }
        }
        hrv = Self.clean(await h); rhr = Self.clean(await k)
        // Stress is not needed to draw the initial trend charts. Calculate it independently so
        // calibration/history work cannot hold the whole Trends screen behind its loading state.
        stress = []
        let requestedRefreshSeq = repo.refreshSeq
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await StressEngine.shared.status(repo: repo)
            guard status.isReady else { return }
            let cal = Calendar.current
            let days = (1...30).compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: Date())) }
            let history = NunaStressHistory()
            await history.ensure(days: days, repo: repo)
            guard repo.refreshSeq == requestedRefreshSeq else { return }
            self.stress = days.sorted().compactMap { d in
                let key = Repository.localDayKey(d)
                return history.entries[key]?.mean.map { (day: key, value: $0) }
            }
        }
        var st = Self.clean(await t)
        if st.isEmpty { st = Self.clean(await repo.exploreSeries(key: "steps", source: "my-whoop", days: 400)) }
        steps = st
        loaded = true
    }

    /// Use the exact per-night Sleep Score calculation shared with the Sleep circle.
    func applySleepScores(from sleep: NunaSleepModel) {
        rest = sleep.nights.compactMap { night in
            sleep.sleepScore(night).map { (day: night.dayKey, value: $0) }
        }.sorted { $0.day < $1.day }
    }

    /// `StressModel` keys its days as UTC midnights.
    nonisolated private static func utcDay(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private static func clean(_ s: [(day: String, value: Double)]) -> Series {
        Dictionary(s.map { ($0.day, $0.value) }, uniquingKeysWith: { _, l in l }).map { (day: $0.key, value: $0.value) }.sorted { $0.day < $1.day }
    }

    /// Readings in the `days` days ending `back` days before today (back 0 = the window ending today).
    func window(_ s: Series, days: Int, back: Int = 0) -> Series {
        guard let hi = TrendInsights.shift(todayKey, by: -back), let lo = TrendInsights.shift(todayKey, by: -(back + days - 1)) else { return [] }
        return s.filter { $0.day >= lo && $0.day <= hi }
    }

    func mean(_ s: Series) -> Double? { s.isEmpty ? nil : s.map(\.value).reduce(0, +) / Double(s.count) }

    /// Mean of the current window and of the window right before it.
    func means(_ s: Series, days: Int, back: Int = 0) -> (now: Double?, before: Double?) {
        (mean(window(s, days: days, back: back)), mean(window(s, days: days, back: back + days)))
    }

    func date(_ day: String) -> Date? { Self.parser.date(from: day) }
    private static let parser: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    var hasAnything: Bool { !charge.isEmpty || !effort.isEmpty || !rest.isEmpty }
}

// MARK: - Formatting shared by the Trends screens

enum NunaTrendsFormat {
    static func short(_ d: Date) -> String { nunaAxisDate(d) }

    /// "Wed, 30 Sep".
    static func withWeekday(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = AppLanguage.activeLocale; f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f.string(from: d)
    }

    static func weekdayShort(_ w: Int) -> String {
        let f = DateFormatter(); f.locale = AppLanguage.activeLocale
        return f.shortWeekdaySymbols[(w - 1) % 7]
    }

    static func num(_ v: Double?, _ digits: Int = 0) -> String {
        v.map { String(format: "%.\(digits)f", locale: AppLanguage.activeLocale, $0) } ?? "–"
    }

    static func signed(_ v: Double, _ digits: Int = 1) -> String {
        (v >= 0 ? "+" : "−") + String(format: "%.\(digits)f", locale: AppLanguage.activeLocale, abs(v))
    }

    static func strengthLabel(_ r: Double) -> String {
        switch TrendInsights.strength(r) {
        case .weak: return String(localized: "Weak")
        case .moderate: return String(localized: "Moderate")
        case .strong: return String(localized: "Strong")
        }
    }

    /// "Moderate · −0,59".
    static func relationChip(_ r: Double) -> String {
        strengthLabel(r) + " · " + String(format: "%.2f", locale: AppLanguage.activeLocale, r).replacingOccurrences(of: "-", with: "−")
    }
}

/// Which trailing window the Trends screens show.
enum NunaTrendsRange: Int, CaseIterable, Identifiable {
    case week = 7, month = 30, halfYear = 180, year = 365
    var id: Int { rawValue }
    /// The same choices for the shared range switch of the trend cards.
    static let choices: [(value: Int, title: String)] = [(7, "W\u{2060}"), (30, "M"), (180, "6M"), (365, "1Y")]
    static var options: [(value: Int, title: LocalizedStringKey)] {
        [(7, "W\u{2060}"), (30, "M"), (180, "6M"), (365, "1Y")]
    }
}
#endif
