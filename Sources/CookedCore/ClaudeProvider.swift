import Foundation

public actor ClaudeProvider: UsageProvider {
    private struct Credentials: Decodable {
        struct OAuth: Decodable { let accessToken: String? }
        let claudeAiOauth: OAuth?
    }
    private struct Config: Decodable {
        struct Account: Decodable { let seatTier: String? }
        let oauthAccount: Account?
    }
    private struct Window: Decodable, Sendable {
        let utilization: Double?
        let resets_at: String?
    }
    private let home: URL
    private let http: HTTPClient
    private let command: CredentialCommand
    private let estimator: CostEstimator
    private var cache = UsageCache<[String: Window]>()

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                http: HTTPClient = HTTPClient(), estimator: CostEstimator? = nil,
                command: @escaping CredentialCommand = { Command.output($0, $1) }) {
        self.home = home; self.http = http; self.command = command
        self.estimator = estimator ?? CostEstimator(root: home.appendingPathComponent(".claude/projects"), source: .claude)
    }

    public func fetch(now: Date) async -> ProviderSnapshot? {
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path)
                || FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude.json").path) else { return nil }
        async let local = estimator.summary(now: now)
        let note = await fetchQuota(now: now)
        let costs = await local
        var metrics = quotaMetrics(now: now)
        let hasLocal = costs.today.requests + costs.week.requests + costs.month.requests > 0
        if hasLocal {
            for (label, period, cost) in [("Today", MetricPeriod.today, costs.today), ("This week", .week, costs.week), ("This month", .month, costs.month)] {
                metrics.append(Metric(label, cost.usd.map(Format.cost) ?? "\(Format.count(cost.tokens)) tokens", period: period,
                    detail: "\(Format.count(cost.tokens)) tokens · \(cost.requests) requests"))
            }
        }
        let details = costs.month.models.sorted {
            if $0.value.usd != $1.value.usd { return ($0.value.usd ?? -1) > ($1.value.usd ?? -1) }
            return $0.key < $1.key
        }.map { model, cost in
            Metric(Format.modelName(model), cost.usd.map(Format.cost) ?? "\(Format.count(cost.tokens)) tokens",
                   detail: "\(Format.count(cost.tokens)) tokens · \(cost.requests) req")
        }
        var notes = note.map { [$0] } ?? []
        notes.append(hasLocal ? "Estimate from this Mac's logs only; may be incomplete. Not billed spend." : "No recent local usage logs; cost estimate unavailable.")
        let unknown = costs.today.unknownModels.union(costs.week.unknownModels).union(costs.month.unknownModels)
        if !unknown.isEmpty { notes.append("Incomplete estimate; unknown price: " + unknown.sorted().joined(separator: ", ") + ".") }
        let config = (try? Data(contentsOf: home.appendingPathComponent(".claude.json")))
            .flatMap { try? JSONDecoder().decode(Config.self, from: $0) }?.oauthAccount
        return ProviderSnapshot(title: "Claude", subtitle: config?.seatTier,
                                todayUSD: costs.today.usd, weekUSD: costs.week.usd, monthUSD: costs.month.usd,
                                monthTokens: costs.month.tokens, monthRequests: costs.month.requests,
                                metrics: metrics, details: details, notes: notes)
    }

    private func quotaMetrics(now: Date) -> [Metric] {
        (cache.value ?? [:]).sorted { $0.key < $1.key }.compactMap { key, window in
            guard let percent = window.utilization, percent.isFinite, percent >= 0 else { return nil }
            let labels = ["five_hour": "Current window", "seven_day": "Weekly window", "seven_day_opus": "Weekly Opus", "seven_day_sonnet": "Weekly Sonnet"]
            return Metric(labels[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized,
                          Format.percent(percent), progress: min(percent / 100, 1),
                          detail: providerDate(window.resets_at).map { Format.reset($0, now: now) })
        }
    }

    private func fetchQuota(now: Date) async -> String? {
        if let waiting = cache.waiting(now: now) { return waiting }
        guard let raw = command("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]),
              let credentials = try? JSONDecoder().decode(Credentials.self, from: Data(raw.utf8)),
              let token = credentials.claudeAiOauth?.accessToken, !token.isEmpty else {
            return "Claude credentials unavailable; sign in with Claude Code." + cache.stale
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        do {
            let data = try await http.data(for: request)
            // Extra usage is an amount, not a quota window; tolerate new unrelated fields.
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            var windows: [String: Window] = [:]
            for (key, value) in object where key == "five_hour" || key.hasPrefix("seven_day") {
                guard !(value is NSNull) else { continue }
                guard value is [String: Any] else { return "Usage API response format changed." + cache.stale }
                windows[key] = try JSONDecoder().decode(Window.self, from: JSONSerialization.data(withJSONObject: value))
            }
            guard windows.values.contains(where: { ($0.utilization ?? -1) >= 0 }) else {
                return "Usage API returned no supported quota windows." + cache.stale
            }
            cache.value = windows; cache.retryAt = nil
            return nil
        } catch { return cache.failure(error, now: now, login: "Sign in with Claude Code again." + cache.stale) }
    }
}

