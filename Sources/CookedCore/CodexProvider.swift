import Foundation

public actor CodexProvider: UsageProvider {
    private struct Auth: Decodable {
        struct Tokens: Decodable { let access_token: String?; let account_id: String? }
        let tokens: Tokens?
    }
    private struct Quota: Decodable, Sendable {
        struct Window: Decodable, Sendable { let used_percent: Double?; let utilization: Double?; let reset_at: Double? }
        struct Limits: Decodable, Sendable { let primary_window: Window?; let secondary_window: Window? }
        struct Credits: Decodable, Sendable { let used: Double?; let limit: Double?; let used_percent: Double?; let reset_at: Double? }
        struct Spend: Decodable, Sendable { let individual_limit: Credits? }
        struct CreditStatus: Decodable, Sendable { let has_credits: Bool? }
        let credits: CreditStatus?
        let plan_type: String?
        let rate_limit: Limits?
        let spend_control: Spend?

        func metrics(now: Date) -> [Metric] {
            var result: [Metric] = []
            for (name, window) in [("Current window", rate_limit?.primary_window), ("Weekly window", rate_limit?.secondary_window)] {
                guard let window, let percent = window.used_percent ?? window.utilization, percent.isFinite else { continue }
                let reset = window.reset_at.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
                result.append(Metric(name, Format.percent(percent), progress: min(max(percent / 100, 0), 1),
                                     detail: reset.map { Format.reset($0, now: now) }))
            }
            if let credits = spend_control?.individual_limit {
                let percent = credits.used_percent ?? credits.used.flatMap { used in
                    credits.limit.flatMap { $0 > 0 ? used / $0 * 100 : nil }
                }
                if let percent, percent.isFinite {
                    let amount = credits.used.flatMap { used in credits.limit.map { "\(Format.compact(used)) / \(Format.compact($0)) cr" } }
                    let value = Format.percent(percent) + (amount.map { " · " + $0 } ?? "")
                    let reset = credits.reset_at.flatMap { $0.isFinite ? Format.reset(Date(timeIntervalSince1970: $0), now: now) : nil }
                    result.append(Metric("Monthly credits", value, progress: min(max(percent / 100, 0), 1), detail: reset))
                }
            }
            return result
        }
    }

    private let home: URL
    private let http: HTTPClient
    private let estimator: CostEstimator
    private var lastGood: Quota?
    private var retryAt: Date?

    public init(home: URL = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
                http: HTTPClient = HTTPClient(), estimator: CostEstimator? = nil) {
        self.home = home; self.http = http
        self.estimator = estimator ?? CostEstimator(root: home.appendingPathComponent("sessions"))
    }

    public func fetch(now: Date) async -> ProviderSnapshot? {
        async let local = estimator.summary(now: now)
        let response = await fetchQuota(now: now)
        let costs = await local
        let hasLocal = costs.today.requests > 0 || costs.week.requests > 0 || costs.month.requests > 0
        guard !response.hidden || hasLocal else { return nil }
        let quota = response.quota
        let quotaMetrics = quota?.metrics(now: now) ?? []
        var metrics = quotaMetrics
        if hasLocal {
            for (label, period, cost) in [("Today", MetricPeriod.today, costs.today), ("This week", .week, costs.week), ("This month", .month, costs.month)] {
                metrics.append(Metric(label, cost.usd.map(Format.cost) ?? "\(Format.count(cost.tokens)) tokens", period: period,
                    detail: (cost.usd == nil ? "" : "\(Format.count(cost.tokens)) tokens · ") + "\(cost.requests) requests"))
            }
        }
        let details = costs.month.models.sorted {
            if $0.value.usd != $1.value.usd { return ($0.value.usd ?? -1) > ($1.value.usd ?? -1) }
            if $0.value.tokens != $1.value.tokens { return $0.value.tokens > $1.value.tokens }
            return $0.key < $1.key
        }.map { model, cost in
            Metric(Format.modelName(model), cost.usd.map(Format.cost) ?? "\(Format.count(cost.tokens)) tokens",
                   detail: (cost.usd == nil ? "" : "\(Format.count(cost.tokens)) tokens · ") + "\(cost.requests) req")
        }
        var notes = response.note.map { [$0] } ?? []
        if quotaMetrics.isEmpty { notes.insert("Limits unavailable; Codex auth or usage API missing.", at: 0) }
        if quota?.credits?.has_credits == true { notes.append("Credits are workspace units, not USD.") }
        let unknown = costs.today.unknownModels.union(costs.week.unknownModels).union(costs.month.unknownModels)
        if !unknown.isEmpty {
            let partial = [costs.today.usd, costs.week.usd, costs.month.usd].contains { $0 != nil }
            notes.append((partial ? "Partial estimate; unknown price: " : "Price unavailable: ") + unknown.sorted().joined(separator: ", ") + ".")
        }
        return ProviderSnapshot(title: "Codex", subtitle: quota?.plan_type?.capitalized,
                                todayUSD: costs.today.usd, weekUSD: costs.week.usd, monthUSD: costs.month.usd,
                                monthTokens: costs.month.tokens, monthRequests: costs.month.requests,
                                metrics: metrics, details: details, notes: notes)
    }

    private func fetchQuota(now: Date) async -> (quota: Quota?, note: String?, hidden: Bool) {
        if let retryAt, retryAt > now {
            return (lastGood, "retry in \(Int(ceil(retryAt.timeIntervalSince(now) / 60)))m", false)
        }
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let tokens = (try? JSONDecoder().decode(Auth.self, from: data))?.tokens,
              let token = tokens.access_token, !token.isEmpty else {
            return (lastGood, lastGood == nil ? nil : "Run codex login to sign in again.", lastGood == nil)
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(tokens.account_id, forHTTPHeaderField: "chatgpt-account-id")
        do {
            let data = try await http.data(for: request)
            let quota = try JSONDecoder().decode(Quota.self, from: data)
            guard !quota.metrics(now: now).isEmpty else { return (lastGood ?? quota, "Quota unavailable · empty response", false) }
            lastGood = quota; retryAt = nil
            return (quota, nil, false)
        } catch HTTPError.rateLimited(let seconds) {
            retryAt = now.addingTimeInterval(seconds)
            return (lastGood, "retry in \(Int(ceil(seconds / 60)))m", false)
        } catch HTTPError.status(let code) where code == 401 {
            return (lastGood, "Run codex login to sign in again.", lastGood == nil)
        } catch HTTPError.status(let code) where code == 403 {
            return (lastGood, lastGood == nil ? nil : "Limits unavailable; Codex auth or usage API missing.", lastGood == nil)
        } catch {
            return (lastGood, "Quota unavailable · retrying in 60s", false)
        }
    }
}
