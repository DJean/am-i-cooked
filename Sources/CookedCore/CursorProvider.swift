import Foundation

public actor CursorProvider: UsageProvider {
    private struct Quota: Decodable, Sendable {
        struct Bucket: Decodable, Sendable {
            let used: Double?
            let limit: Double?
            var valid: Bool { used.map { $0.isFinite && $0 >= 0 } == true && limit.map { $0.isFinite && $0 > 0 } == true }
        }
        struct Individual: Decodable, Sendable { let overall: Bucket?; let plan: Bucket? }
        struct Team: Decodable, Sendable { let pooled: Bucket?; let onDemand: Bucket? }
        let membershipType: String?
        let billingCycleEnd: String?
        let individualUsage: Individual?
        let teamUsage: Team?
        var selected: (String, Bucket)? {
            for (label, bucket) in [("Individual allowance", individualUsage?.overall), ("Team pooled allowance", teamUsage?.pooled), ("Team on-demand", teamUsage?.onDemand), ("Individual plan", individualUsage?.plan)] {
                if let bucket, bucket.valid { return (label, bucket) }
            }
            return nil
        }
    }
    private let database: URL
    private let http: HTTPClient
    private let command: CredentialCommand
    private var cache = UsageCache<Quota>()

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                http: HTTPClient = HTTPClient(), command: @escaping CredentialCommand = { Command.output($0, $1) }) {
        database = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        self.http = http; self.command = command
    }

    public func fetch(now: Date) async -> ProviderSnapshot? {
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        let note = await fetchQuota(now: now)
        var metrics: [Metric] = []
        if let (label, bucket) = cache.value?.selected, let used = bucket.used, let limit = bucket.limit {
            let ratio = used / limit
            if ratio.isFinite && (ratio * 100).isFinite {
                metrics.append(Metric(label, "\(Format.percent(ratio * 100)) · \(Format.cost(used / 100)) / \(Format.cost(limit / 100))",
                                      progress: min(ratio, 1), detail: providerDate(cache.value?.billingCycleEnd).map { Format.reset($0, now: now) }))
            }
        }
        // Billing-cycle and team usage are not this user's calendar-month spend.
        return ProviderSnapshot(title: "Cursor", subtitle: cache.value?.membershipType?.capitalized,
                                metrics: metrics, notes: note.map { [$0] } ?? [])
    }

    private func fetchQuota(now: Date) async -> String? {
        if let waiting = cache.waiting(now: now) { return waiting }
        guard let token = command("/usr/bin/sqlite3", ["-readonly", database.path, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"]),
              let user = Self.userID(token) else { return "Cursor credentials unavailable; reopen Cursor and sign in." + cache.stale }
        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        request.setValue("WorkosCursorSessionToken=\(user)::\(token)", forHTTPHeaderField: "Cookie")
        do {
            let quota = try JSONDecoder().decode(Quota.self, from: await http.data(for: request))
            guard quota.selected != nil else { return "Usage API returned no supported allowance." + cache.stale }
            cache.value = quota; cache.retryAt = nil
            return nil
        } catch { return cache.failure(error, now: now, login: "Reopen Cursor to sign in again." + cache.stale) }
    }

    private static func userID(_ token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, token.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0) }) else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        struct Claims: Decodable { let sub: String }
        guard let data = Data(base64Encoded: encoded), let claims = try? JSONDecoder().decode(Claims.self, from: data),
              let user = claims.sub.split(separator: "|").last, !user.isEmpty,
              user.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }) else { return nil }
        return String(user)
    }
}
