import Foundation

/// The installed version, for the places that show it.
enum AppVersion {
    /// The real marketing version straight from the bundle (CFBundleShortVersionString, set from project.yml MARKETING_VERSION), so what is
    /// shown can never be a hand-edited constant gone stale.
    static var installed: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? AppChangelog.currentVersion
    }
}
