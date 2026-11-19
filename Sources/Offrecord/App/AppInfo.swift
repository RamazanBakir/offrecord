import Foundation

/// Version and project links read from the app bundle's Info.plist.
enum AppInfo {
    static let repositoryURL = URL(string: "https://github.com/RamazanBakir/offrecord")!
    static let releasesURL = repositoryURL.appending(path: "releases")
    static let issuesURL = repositoryURL.appending(path: "issues")

    /// Marketing version, e.g. "0.1.0".
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
