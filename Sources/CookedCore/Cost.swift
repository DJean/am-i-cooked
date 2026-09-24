import Foundation

public struct ModelCostSummary: Sendable {
    public var usd: Double?
    public var tokens = 0
    public var requests = 0
}

public struct CostSummary: Sendable {
    public var usd: Double?
    public var tokens = 0
    public var requests = 0
    public var unknownModels: Set<String> = []
    public var models: [String: ModelCostSummary] = [:]

    mutating func add(model: String, tokens: Int, cost: Double?) {
        let total = self.tokens.addingReportingOverflow(tokens)
        self.tokens = total.overflow ? Int.max : total.partialValue
        requests += 1
        var detail = models[model] ?? ModelCostSummary()
        let modelTotal = detail.tokens.addingReportingOverflow(tokens)
        detail.tokens = modelTotal.overflow ? Int.max : modelTotal.partialValue
        detail.requests += 1
        if let cost {
            usd = (usd ?? 0) + cost; detail.usd = (detail.usd ?? 0) + cost
        } else { unknownModels.insert(model) }
        models[model] = detail
    }

    mutating func normalize() {
        if requests == 0 || (usd == 0 && !unknownModels.isEmpty) { usd = nil }
        for model in unknownModels where models[model]?.usd == 0 { models[model]?.usd = nil }
    }
}

public struct PeriodCosts: Sendable {
    public var today = CostSummary()
    public var week = CostSummary()
    public var month = CostSummary()
}

private struct TokenUsage: Decodable, Sendable {
    var input = 0, cachedInput = 0, cacheWrite = 0, output = 0
    var cacheWriteHour = 0
    var total: Int { input + output }
    enum CodingKeys: String, CodingKey {
        case input = "input_tokens", cachedInput = "cached_input_tokens"
        case cacheWrite = "cache_write_input_tokens", output = "output_tokens"
    }
    init() {}
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        input = max(0, try values.decodeIfPresent(Int.self, forKey: .input) ?? 0)
        cachedInput = max(0, try values.decodeIfPresent(Int.self, forKey: .cachedInput) ?? 0)
        cacheWrite = max(0, try values.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0)
        output = max(0, try values.decodeIfPresent(Int.self, forKey: .output) ?? 0)
        guard !input.addingReportingOverflow(output).overflow else {
            throw DecodingError.dataCorruptedError(forKey: .output, in: values, debugDescription: "Token total exceeds Int.max")
        }
    }
    func delta(from previous: Self) -> Self {
        var result = Self()
        result.input = max(0, input - previous.input)
        result.cachedInput = max(0, cachedInput - previous.cachedInput)
        result.cacheWrite = max(0, cacheWrite - previous.cacheWrite)
        result.output = max(0, output - previous.output)
        return result
    }
}

private struct ModelPrice: Decodable, Sendable {
    let litellm_provider: String?
    let input_cost_per_token, output_cost_per_token: Double?
    let cache_read_input_token_cost, cache_creation_input_token_cost: Double?
    let input_cost_per_token_above_272k_tokens, output_cost_per_token_above_272k_tokens: Double?
    let cache_read_input_token_cost_above_272k_tokens, cache_creation_input_token_cost_above_272k_tokens: Double?

    let input_cost_per_token_above_200k_tokens, output_cost_per_token_above_200k_tokens: Double?
    let cache_read_input_token_cost_above_200k_tokens, cache_creation_input_token_cost_above_200k_tokens: Double?
    let cache_creation_input_token_cost_above_1hr, cache_creation_input_token_cost_above_1hr_above_200k_tokens: Double?

    func cost(_ usage: TokenUsage) -> Double? {
        let tier = [input_cost_per_token_above_272k_tokens, output_cost_per_token_above_272k_tokens,
                    cache_read_input_token_cost_above_272k_tokens, cache_creation_input_token_cost_above_272k_tokens]
        let long = usage.input > 272_000 && tier.contains { $0 != nil }
        var rates = [
            long ? input_cost_per_token_above_272k_tokens : input_cost_per_token,
            long ? cache_read_input_token_cost_above_272k_tokens : cache_read_input_token_cost,
            long ? cache_creation_input_token_cost_above_272k_tokens : cache_creation_input_token_cost,
            long ? output_cost_per_token_above_272k_tokens : output_cost_per_token
        ]
        let claudeTier = [input_cost_per_token_above_200k_tokens, cache_read_input_token_cost_above_200k_tokens,
                          cache_creation_input_token_cost_above_200k_tokens, output_cost_per_token_above_200k_tokens]
        let claudeLong = litellm_provider == "anthropic" && usage.input > 200_000 && claudeTier.contains { $0 != nil }
        if claudeLong { rates = claudeTier }
        rates.append(claudeLong ? cache_creation_input_token_cost_above_1hr_above_200k_tokens : cache_creation_input_token_cost_above_1hr)
        let counts = [max(0, max(0, usage.input - usage.cachedInput) - usage.cacheWrite),
                      usage.cachedInput, usage.cacheWrite - usage.cacheWriteHour, usage.output, usage.cacheWriteHour]
        var total = 0.0
        for (count, rate) in zip(counts, rates) where count > 0 {
            guard let rate, rate.isFinite, rate >= 0 else { return nil }
            total += Double(count) * rate
        }
        return total.isFinite ? total : nil
    }
}

public actor PriceCatalog {
    private let http: HTTPClient
    private var prices: [String: ModelPrice]?
    private var pending: Task<[String: ModelPrice]?, Never>?

    public init(http: HTTPClient = HTTPClient()) { self.http = http }

    fileprivate func values() async -> [String: ModelPrice] {
        if let prices { return prices }
        if let pending { return await pending.value ?? [:] }
        let http = http
        let task = Task { () -> [String: ModelPrice]? in
            let url = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
            let request = URLRequest(url: url, timeoutInterval: 5)
            guard let data = try? await http.data(for: request),
                  let decoded = try? JSONDecoder().decode([String: ModelPrice].self, from: data) else { return nil }
            let models = decoded.filter {
                !$0.key.contains("/") && ["openai", "anthropic"].contains($0.value.litellm_provider ?? "") &&
                $0.value.input_cost_per_token != nil && $0.value.output_cost_per_token != nil &&
                $0.value.cache_read_input_token_cost != nil
            }
            guard !models.isEmpty else { return nil }
            return models.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        }
        pending = task
        prices = await task.value
        pending = nil
        return prices ?? [:]
    }
}

// Decoding deliberately has no conversation-content fields, even for unrelated JSONL records.
private struct UsageRecord: Decodable {
    let type: String
    let timestamp: String?
    let payload: Payload?
    enum CodingKeys: CodingKey { case type, timestamp, payload }
    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        type = try fields.decode(String.self, forKey: .type)
        timestamp = try fields.decodeIfPresent(String.self, forKey: .timestamp)
        payload = ["session_meta", "turn_context", "event_msg"].contains(type)
            ? try fields.decodeIfPresent(Payload.self, forKey: .payload) : nil
    }
    struct Payload: Decodable {
        let type, model, timestamp, forked_from_id: String?
        let started_at: StartTime?
        let thread_settings: Settings?
        let info: Info?
    }
    struct Settings: Decodable { let model: String? }
    struct Info: Decodable { let total_token_usage: TokenUsage? }
    enum StartTime: Decodable {
        case seconds(Double), iso(String)
        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self) { self = .seconds(seconds) }
            else { self = .iso(try value.decode(String.self)) }
        }
    }
}

private struct ClaudeUsageRecord: Decodable {
    let type: String
    let timestamp: String?
    let requestId: String?
    let message: Message?
    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }
    struct Usage: Decodable {
        let input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens: Int?
        let cache_creation: CacheCreation?
        struct CacheCreation: Decodable { let ephemeral_1h_input_tokens: Int? }
        func tokens() -> TokenUsage? {
            let counts = [input_tokens ?? 0, cache_read_input_tokens ?? 0, cache_creation_input_tokens ?? 0, output_tokens ?? 0]
            guard counts.allSatisfy({ $0 >= 0 }) else { return nil }
            var sum = 0
            for count in counts {
                let next = sum.addingReportingOverflow(count)
                guard !next.overflow else { return nil }
                sum = next.partialValue
            }
            var result = TokenUsage()
            result.input = sum - counts[3]; result.output = counts[3]
            result.cachedInput = counts[1]; result.cacheWrite = counts[2]
            result.cacheWriteHour = cache_creation?.ephemeral_1h_input_tokens ?? 0
            guard result.cacheWriteHour >= 0, result.cacheWriteHour <= result.cacheWrite else { return nil }
            return result
        }
    }
}

public actor CostEstimator {
    public enum Source: Sendable { case codex, claude }
    private struct Entry {
        let date: Date, model: String, usage: TokenUsage
        var identity: String? = nil
    }
    private struct CachedFile {
        let modified: Date, size: Int, entries: [Entry]
    }
    private let root: URL, catalog: PriceCatalog, calendar: Calendar
    private let source: Source
    private var files: [URL: CachedFile] = [:]
    private var previousCutoff: Date?

    public init(root: URL, catalog: PriceCatalog = PriceCatalog(), calendar: Calendar = .current, source: Source = .codex) {
        self.source = source
        self.root = root; self.catalog = catalog
        var calendar = calendar; calendar.firstWeekday = 2
        self.calendar = calendar
    }

    public func summary(now: Date) async -> PeriodCosts {
        guard FileManager.default.fileExists(atPath: root.path) else { return PeriodCosts() }
        async let loadedPrices = catalog.values()
        let today = calendar.startOfDay(for: now)
        let week = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let month = calendar.dateInterval(of: .month, for: now)!.start
        let cutoff = min(week, month)
        if cutoff != previousCutoff { files.removeAll(); previousCutoff = cutoff }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                       options: [.skipsHiddenFiles])
        var present: Set<URL> = []
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "jsonl", let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true, let modified = values.contentModificationDate,
                  modified >= cutoff, let size = values.fileSize else { continue }
            present.insert(file)
            if files[file]?.modified == modified && files[file]?.size == size { continue }
            if let data = try? Data(contentsOf: file, options: .mappedIfSafe) {
                files[file] = CachedFile(modified: modified, size: size, entries: parse(data, cutoff: cutoff))
            }
        }
        files = files.filter { present.contains($0.key) }
        let allEntries = files.sorted { $0.key.path < $1.key.path }.flatMap { $0.value.entries }
        var unique: [String: Entry] = [:], entries: [Entry] = []
        for entry in allEntries {
            if let id = entry.identity {
                if let previous = unique[id], previous.usage.total > entry.usage.total { continue }
                unique[id] = entry
            } else { entries.append(entry) }
        }
        entries.append(contentsOf: unique.values)
        let prices = await loadedPrices
        var result = PeriodCosts()
        for entry in entries where entry.date <= now {
            let cost = prices[entry.model]?.cost(entry.usage)
            if entry.date >= today { result.today.add(model: entry.model, tokens: entry.usage.total, cost: cost) }
            if entry.date >= week { result.week.add(model: entry.model, tokens: entry.usage.total, cost: cost) }
            if entry.date >= month { result.month.add(model: entry.model, tokens: entry.usage.total, cost: cost) }
        }
        result.today.normalize(); result.week.normalize(); result.month.normalize()
        return result
    }

    private func parse(_ data: Data, cutoff: Date) -> [Entry] {
        if source == .claude { return parseClaude(data, cutoff: cutoff) }
        let decoder = JSONDecoder(), iso = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ value: String?) -> Date? {
            value.flatMap { fractional.date(from: $0) ?? iso.date(from: $0) }
        }
        var entries: [Entry] = [], previous = TokenUsage(), model = "unknown", replayUntil: Date?
        for line in data.split(separator: 10) {
            guard let row = try? decoder.decode(UsageRecord.self, from: Data(line)), let payload = row.payload else { continue }
            if row.type == "session_meta", payload.forked_from_id != nil {
                replayUntil = date(payload.timestamp) ?? date(row.timestamp) ?? .distantFuture
            }
            if row.type == "turn_context", let name = payload.model { model = name.lowercased() }
            if row.type == "event_msg", payload.type == "thread_settings_applied",
               let name = payload.thread_settings?.model { model = name.lowercased() }
            if let fork = replayUntil, payload.type == "task_started", let start = payload.started_at {
                let started: Date?
                switch start {
                case .seconds(let seconds): started = seconds.isFinite ? Date(timeIntervalSince1970: seconds) : nil
                case .iso(let value): started = date(value)
                }
                if let started, started.timeIntervalSince1970 >= floor(fork.timeIntervalSince1970) { replayUntil = nil }
            }
            guard row.type == "event_msg", payload.type == "token_count",
                  let total = payload.info?.total_token_usage else { continue }
            let usage = total.delta(from: previous)
            previous = total // Replayed and pre-window totals still establish the cumulative baseline.
            guard replayUntil == nil, usage.total > 0 || usage.cacheWrite > 0, let timestamp = date(row.timestamp), timestamp >= cutoff else { continue }
            entries.append(Entry(date: timestamp, model: model, usage: usage))
        }
        return entries
    }
    private func parseClaude(_ data: Data, cutoff: Date) -> [Entry] {
        let decoder = JSONDecoder(), iso = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return data.split(separator: 10).compactMap { line in
            guard let row = try? decoder.decode(ClaudeUsageRecord.self, from: Data(line)),
                  row.type == "assistant", let message = row.message,
                  let model = message.model, !model.hasPrefix("<"),
                  let usage = message.usage?.tokens(), usage.total > 0,
                  let timestamp = row.timestamp,
                  let date = fractional.date(from: timestamp) ?? iso.date(from: timestamp), date >= cutoff else { return nil }
            return Entry(date: date, model: model.lowercased(), usage: usage,
                         identity: message.id.map { (row.requestId ?? "") + ":" + $0 })
        }
    }

}
