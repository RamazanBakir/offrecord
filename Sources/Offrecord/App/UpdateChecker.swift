import Foundation
import Observation

/// Asks GitHub for the latest published release and remembers whether it is newer
/// than the running version. Sends no data besides a plain HTTPS request; can be turned off.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Equatable, Sendable {
        let version: String
        let pageURL: URL
    }

    enum Status: Equatable {
        case idle, checking, upToDate, available(String), failed
    }

    static let enabledKey = "checkForUpdates"
    private static let skippedKey = "skippedUpdateVersion"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let interval: TimeInterval = 12 * 60 * 60
    private nonisolated static let endpoint = URL(string: "https://api.github.com/repos/RamazanBakir/offrecord/releases/latest")!

    /// Newer release the user has not dismissed; drives the banner.
    private(set) var available: Release?
    private(set) var status: Status = .idle
    private var timer: Timer?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            newValue ? start() : stop()
        }
    }

    init() {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
    }

    /// Checks now if the last check is old enough, then twice a day while the app runs.
    func start() {
        guard isEnabled else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > Self.interval { Task { await check(manual: false) } }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in await AppModel.shared.updates.check(manual: false) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// A manual check ignores a previously skipped version.
    func check(manual: Bool) async {
        status = .checking
        do {
            let release = try await Self.fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            guard Self.isVersion(release.version, newerThan: AppInfo.version) else {
                available = nil
                status = .upToDate
                return
            }
            status = .available(release.version)
            let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
            available = manual || skipped != release.version ? release : nil
        } catch {
            status = .failed
        }
    }

    /// Hides the banner until the next release.
    func skipAvailable() {
        guard let available else { return }
        UserDefaults.standard.set(available.version, forKey: Self.skippedKey)
        self.available = nil
    }

    /// Hides the banner for this launch only.
    func dismissForNow() {
        available = nil
    }

    nonisolated static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Offrecord-update-check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Payload: Decodable { let tag_name: String; let html_url: URL }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(version: version, pageURL: payload.html_url)
    }

    /// Compares dotted numeric versions: "0.10.0" is newer than "0.9.2".
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
