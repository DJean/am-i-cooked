import Foundation

public struct ModelCompany: Sendable {
    public let id: String
    public let name: String
    public let priceSources: [String]
}

public struct ModelBenchmark: Decodable, Sendable {
    public var name: String
    public var score: Double
    public var metric: String?
    public var version: String?
    public var variant: String?
    public var dataset: String?
    public var harness: String? = nil
}

public struct CatalogDeployment: Sendable, Equatable {
    public var host: String
    public var modelID: String
    public init(host: String, modelID: String) { self.host = host; self.modelID = modelID }
}

public struct CatalogModel: Decodable, Sendable {
    public var id: String
    public var name: String
    public var releaseDate: String?
    public var benchmarks: [ModelBenchmark]?
    public var cost: CatalogPrice? = nil
    public var priceSource: String? = nil
    public var deployments: [CatalogDeployment]? = nil
    public var description: String? = nil
    public var lastUpdated: String? = nil
    public var knowledge: String? = nil
    public var limits: Limits? = nil
    public var modalities: Modalities? = nil
    public struct Limits: Decodable, Sendable { public var context: Int?; public var output: Int? }
    public struct Modalities: Decodable, Sendable { public var input: [String]?; public var output: [String]? }
    enum CodingKeys: String, CodingKey {
        case id, name, benchmarks, description, knowledge, modalities
        case releaseDate = "release_date", lastUpdated = "last_updated", limits = "limit"
    }
    public var date: Date? { ReleaseDates.parse(releaseDate) }
    public var exactDate: Date? { releaseDate?.count == 10 ? date : nil }
}

public struct CatalogPrice: Decodable, Sendable {
    public var input: Double?
    public var output: Double?
    public var cacheRead: Double?
    public var cacheWrite: Double?
    public var tiers: [Tier]?
    public var contextOver200K: Rates?
    enum CodingKeys: String, CodingKey {
        case input, output, tiers
        case cacheRead = "cache_read", cacheWrite = "cache_write", contextOver200K = "context_over_200k"
    }
    public struct Rates: Decodable, Sendable {
        public var input: Double?; public var output: Double?
        public var cacheRead: Double? = nil; public var cacheWrite: Double? = nil
        enum CodingKeys: String, CodingKey {
            case input, output
            case cacheRead = "cache_read", cacheWrite = "cache_write"
        }
    }
    public struct Tier: Decodable, Sendable, Hashable {
        public var input: Double?; public var output: Double?
        public var cacheRead: Double? = nil; public var cacheWrite: Double? = nil
        public var threshold: Threshold? = nil
        enum CodingKeys: String, CodingKey {
            case input, output
            case cacheRead = "cache_read", cacheWrite = "cache_write", threshold = "tier"
        }
        public struct Threshold: Decodable, Sendable, Hashable { public var size: Double? }
        public var label: String { "over \(ModelFigure.score((threshold?.size ?? 200_000) / 1000))K ctx" }
    }
    public var distinctTiers: [Tier] {
        var values = tiers ?? []
        if let old = contextOver200K {
            values.append(Tier(input: old.input, output: old.output, cacheRead: old.cacheRead, cacheWrite: old.cacheWrite))
        }
        var seen: Set<Tier> = []
        return values.filter { value in
            var tier = value
            tier.threshold = Tier.Threshold(size: tier.threshold?.size ?? 200_000)
            let changed = [(tier.input, input), (tier.output, output), (tier.cacheRead, cacheRead), (tier.cacheWrite, cacheWrite)]
                .contains { $0.0 != nil && $0.0 != $0.1 }
            return changed && seen.insert(tier).inserted
        }
    }
}

public enum ReleaseDates {
    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c
    }
    public static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let bytes = Array(value.utf8)
        guard bytes.count == 7 || bytes.count == 10, bytes[4] == 45,
              bytes.count == 7 || bytes[7] == 45 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var n = 0
            for i in range { guard (48...57).contains(bytes[i]) else { return nil }; n = n * 10 + Int(bytes[i] - 48) }
            return n
        }
        guard let year = number(0..<4), year > 0, let month = number(5..<7), (1...12).contains(month),
              let day = bytes.count == 10 ? number(8..<10) : 1, (1...31).contains(day) else { return nil }
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: parts), calendar.dateComponents([.year, .month, .day], from: date) == parts else { return nil }
        return date
    }

    public static func days(_ from: Date, _ to: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }
}

public struct ModelCatalog: Sendable {
    public var models: [CatalogModel] = []
    public var fetchedAt: Date?
    public var error: String?
    public var priceError: String?
    public var priceLoading = false
    public init() {}

    public func merging(previous: Self) -> Self {
        if let error {
            var result = previous; result.error = error; result.priceLoading = false
            return result
        }
        var result = self
        if priceLoading || priceError != nil {
            let old = Dictionary(previous.models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for index in result.models.indices {
                guard let saved = old[result.models[index].id] else { continue }
                if result.models[index].cost == nil {
                    result.models[index].cost = saved.cost; result.models[index].priceSource = saved.priceSource
                }
                result.models[index].deployments = saved.deployments
            }
        }
        return result
    }
    public static func decode(metadata: Data, prices: Data?, companies: [ModelCompany], now: Date) throws -> Self {
        let decoder = JSONDecoder()
        guard let raw = try JSONSerialization.jsonObject(with: metadata) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let allowed = Set(companies.map(\.id))
        var records: [String: CatalogModel] = [:]
        for (id, value) in raw {
            guard var fields = value as? [String: Any],
                  allowed.contains(String(id.prefix { $0 != "/" })), !id.hasSuffix("-latest"),
                  ReleaseDates.parse(fields["release_date"] as? String) != nil else { continue }
            fields["id"] = id
            let benchmarks = fields.removeValue(forKey: "benchmarks") as? [Any]
            if let data = try? JSONSerialization.data(withJSONObject: fields),
               var model = try? decoder.decode(CatalogModel.self, from: data) {
                model.benchmarks = benchmarks?.compactMap { item in
                    guard JSONSerialization.isValidJSONObject(item),
                          let data = try? JSONSerialization.data(withJSONObject: item),
                          let benchmark = try? decoder.decode(ModelBenchmark.self, from: data),
                          !benchmark.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          benchmark.score.isFinite else { return nil }
                    return benchmark
                }
                records[id] = model
            }
        }
        struct Entry: Decodable { let id: String?; let name: String?; let cost: CatalogPrice? }
        struct Provider: Decodable { let name: String?; let models: [String: Entry] }
        let providers = try prices.map { try decoder.decode([String: Provider].self, from: $0) } ?? [:]
        let localIDs = Dictionary(grouping: records.keys, by: { String($0.split(separator: "/", maxSplits: 1).last ?? "") })
        let names = Dictionary(grouping: records.keys, by: { records[$0]!.name.lowercased() })
        func unique(_ keys: [String]?) -> String? { keys?.count == 1 ? keys?.first : nil }
        func canonical(_ rawID: String, name: String?, provider: String) -> String? {
            if records[rawID] != nil { return rawID }
            var converted = rawID
            if provider == "amazon-bedrock" {
                let stripped = rawID.replacingOccurrences(of: "-v[0-9]+(:[0-9]+)?$", with: "", options: .regularExpression)
                let parts = stripped.split(separator: ".").map(String.init)
                let aliases = ["qwen": "alibaba", "zai": "zhipuai", "moonshot": "moonshotai"]
                if let start = parts.firstIndex(where: { allowed.contains(aliases[$0] ?? $0) }), start + 1 < parts.count {
                    converted = (aliases[parts[start]] ?? parts[start]) + "/" + parts.dropFirst(start + 1).joined(separator: ".")
                }
            } else {
                converted = String(rawID.split(separator: "/").last ?? "")
                    .replacingOccurrences(of: "(?<=[0-9])p(?=[0-9])", with: ".", options: .regularExpression)
            }
            if records[converted] != nil { return converted }
            let suffix = String(converted.split(separator: "/", maxSplits: 1).last ?? "")
            if let match = unique(localIDs[suffix]) { return match }
            return name.flatMap { unique(names[$0.lowercased()]) }
        }
        var deployments: [String: [CatalogDeployment]] = [:]
        for (provider, host) in [("amazon-bedrock", "Bedrock"), ("fireworks-ai", "Fireworks")] {
            for (key, entry) in providers[provider]?.models ?? [:] {
                let id = entry.id ?? key
                guard let target = canonical(id, name: entry.name, provider: provider) else { continue }
                let deployment = CatalogDeployment(host: host, modelID: id)
                if deployments[target]?.contains(deployment) != true { deployments[target, default: []].append(deployment) }
            }
        }
        var result = Self(); result.fetchedAt = now
        for company in companies {
            let entries = records.values.filter { $0.id.hasPrefix(company.id + "/") }.sorted {
                $0.date == $1.date ? $0.id < $1.id : ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
            }
            for var model in entries {
                model.deployments = (deployments[model.id] ?? []).sorted { $0.host == $1.host ? $0.modelID < $1.modelID : $0.host < $1.host }
                model.cost = nil; model.priceSource = nil
                let suffix = String(model.id.dropFirst(company.id.count + 1))
                for source in company.priceSources {
                    guard let provider = providers[source], let cost = provider.models[suffix]?.cost else { continue }
                    model.cost = cost; model.priceSource = provider.name ?? source; break
                }
                result.models.append(model)
            }
        }
        return result
    }
}

public enum ModelCatalogClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private static func get(_ path: String, transport: Transport?) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://models.dev/" + path)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let data: Data, response: HTTPURLResponse
        if let transport { (data, response) = try await transport(request) }
        else { (data, response) = try await send(request) }
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 25
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
    public static func fetch(companies: [ModelCompany],
                             onMetadata: @escaping @Sendable (ModelCatalog) async -> Void = { _ in },
                             transport: Transport? = nil) async -> ModelCatalog {
        let priceData = Task { try? await get("api.json", transport: transport) }
        defer { priceData.cancel() }
        do {
            let metadata = try await get("models.json", transport: transport)
            var initial = try ModelCatalog.decode(metadata: metadata, prices: nil, companies: companies, now: Date())
            initial.priceLoading = true
            await onMetadata(initial)
            let prices = await priceData.value
            var result: ModelCatalog
            do { result = try ModelCatalog.decode(metadata: metadata, prices: prices, companies: companies, now: Date()) }
            catch {
                result = try ModelCatalog.decode(metadata: metadata, prices: nil, companies: companies, now: Date())
                result.priceError = "Price data invalid"
            }
            if prices == nil { result.priceError = "Prices unavailable" }
            return result
        } catch {
            var result = ModelCatalog(); result.error = "Models.dev request failed · retry in 60s"; return result
        }
    }
}
