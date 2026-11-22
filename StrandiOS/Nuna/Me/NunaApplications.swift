#if os(iOS)
import SwiftUI
import StrandDesign

/// "Application": the screens that are apps in their own right, in one place (Workouts opens only from here): vital signs and stress monitors, the lab book and naps (and the menstrual cycle while cycle awareness has a reading). Sleep has no entry of its own: its detail is the Rest screen.
struct NunaApplicationsView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var router: NavRouter
    private var stressRoute: NunaTodayRoute {
        MetricCatalog.metric(key: "stress", source: "my-whoop").map { .metric($0) } ?? .allMetrics
    }

    var body: some View {
        NunaDetailScreen("Application") {
            NunaCard(small: true) {
                VStack(spacing: 0) {
                    // The page with every workout opens over this one, like Trends. This is the only way in to it.
                    Button { router.requestedDestination = .workouts } label: {
                        NunaListRow("Workouts", subtitle: "Every session, its history and training load", systemImage: "figure.run", showsChevron: true)
                    }.buttonStyle(.plain)
                    NunaDivider()
                    Button { router.requestedDestination = .trends } label: {
                        NunaListRow("Trends", subtitle: "Recovery, Strain and Sleep over time", systemImage: "chart.line.uptrend.xyaxis", showsChevron: true)
                    }.buttonStyle(.plain)
                    NunaDivider()
                    app(.vitalSigns, "Vital signs", "HRV, resting heart rate, blood oxygen and more", "heart.text.square")
                    NunaDivider()
                    app(stressRoute, "Stress monitor", "Level now and through the day", NunaIcons.stress)
                    NunaDivider()
                    app(.labBook, "Lab book", "Your records", "testtube.2")
                    NunaDivider()
                    app(.sleepNaps(0), "Nap", "Daytime sleep", NunaIcons.nap)
                    // Only when cycle awareness is on and has a reading.
                    if appModel.cyclePhase != nil {
                        NunaDivider()
                        app(.cycle, "Menstrual cycle", "Cycle awareness", NunaIcons.cycle)
                    }
                }
            }
        }
        // These are screens of the Today stack; this stack needs to know how to open them.
        .nunaTodayDestinations()
    }

    private func app(_ route: NunaTodayRoute, _ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, _ icon: String) -> some View {
        NavigationLink(value: route) { NunaListRow(title, subtitle, systemImage: icon, showsChevron: true) }.buttonStyle(.plain)
    }
}
#endif
