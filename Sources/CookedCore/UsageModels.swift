import Foundation

public enum Build {
    public static let version = "0.11.0"
}

public protocol UsageProvider: Sendable {
    func fetch(now: Date) async -> ProviderSnapshot?
}

public enum MetricPeriod: Sendable { case today, week, month }

public struct Metric: Sendable {
    public var label: String
    public var value: String
    public var period: MetricPeriod?
    public var progress: Double?
    public var detail: String?

    public init(_ label: String, _ value: String, period: MetricPeriod? = nil,
                progress: Double? = nil, detail: String? = nil) {
        self.label = label; self.value = value; self.period = period
        self.progress = progress; self.detail = detail
    }
}

public struct ProviderSnapshot: Sendable {
    public var title: String
    public var subtitle: String?
    public var todayUSD: Double?
    public var weekUSD: Double?
    public var monthUSD: Double?
    public var monthTokens: Int
    public var monthRequests: Int
    public var metrics: [Metric]
    public var details: [Metric]
    public var notes: [String]

    public init(title: String, subtitle: String? = nil, todayUSD: Double? = nil,
                weekUSD: Double? = nil, monthUSD: Double? = nil, monthTokens: Int = 0,
                monthRequests: Int = 0, metrics: [Metric] = [], details: [Metric] = [],
                notes: [String] = []) {
        self.title = title; self.subtitle = subtitle; self.todayUSD = todayUSD
        self.weekUSD = weekUSD; self.monthUSD = monthUSD; self.monthTokens = monthTokens
        self.monthRequests = monthRequests; self.metrics = metrics; self.details = details
        self.notes = notes
    }
}

public func fetchProviders(_ providers: [any UsageProvider], now: Date) async -> [ProviderSnapshot] {
    await withTaskGroup(of: (Int, ProviderSnapshot?).self) { group in
        for (index, provider) in providers.enumerated() {
            group.addTask { (index, await provider.fetch(now: now)) }
        }
        var results: [(Int, ProviderSnapshot)] = []
        for await (index, snapshot) in group {
            if let snapshot { results.append((index, snapshot)) }
        }
        return results.sorted {
            if $0.1.metrics.isEmpty != $1.1.metrics.isEmpty { return !$0.1.metrics.isEmpty }
            return $0.0 < $1.0
        }.map(\.1)
    }
}
