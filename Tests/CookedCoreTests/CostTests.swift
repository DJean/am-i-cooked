import Foundation
import Testing
@testable import CookedCore

private let testPrices = #"{"GPT-A":{"litellm_provider":"openai","input_cost_per_token":0.001,"cache_read_input_token_cost":0.0001,"cache_creation_input_token_cost":0.002,"output_cost_per_token":0.01},"gpt-b":{"litellm_provider":"openai","input_cost_per_token":0.002,"cache_read_input_token_cost":0.0001,"output_cost_per_token":0.01}}"#
private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
private func context(_ model: String = "gpt-a") -> String {
    #"{"type":"turn_context","payload":{"model":"\#(model)"}}"#
}
private func usage(_ time: String, _ input: Int, cached: Int = 0, write: Int = 0, output: Int = 0) -> String {
    #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":\#(write),"output_tokens":\#(output)}}}}"#
}

private actor PriceReplies {
    var bodies: [String?]
    private(set) var attempts = 0
    init(_ bodies: [String?]) { self.bodies = bodies }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        attempts += 1
        #expect(request.timeoutInterval == 5)
        guard !bodies.isEmpty, let body = bodies.removeFirst() else { throw URLError(.notConnectedToInternet) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private struct CostFixture {
    let root: URL
    let estimator: CostEstimator
    let replies: PriceReplies
    init(_ prices: [String?] = [testPrices]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        replies = PriceReplies(prices)
        let replies = replies
        let catalog = PriceCatalog(http: HTTPClient { try await replies.send($0) })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        calendar.firstWeekday = 1 // Estimator must override the locale's Sunday start.
        estimator = CostEstimator(root: root, catalog: catalog, calendar: calendar)
    }
    func write(_ lines: [String], name: String = "usage.jsonl", modified: Date = instant("2026-09-12T04:00:00Z")) throws {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test func cumulativeDeltasModelChangesAndTokenCategories() async throws {
    let f = try CostFixture(); defer { f.clean() }
    let time = "2026-09-12T03:00:00Z"
    try f.write([
        context("GPT-A"), usage(time, 100, cached: 20, write: 10, output: 5),
        usage(time, 100, cached: 20, write: 10, output: 5), // Rate-limit-only duplicate.
        usage(time, 180, cached: 50, write: 20, output: 10),
        #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-b"}}}"#,
        usage(time, 280, cached: 50, write: 20, output: 15),
        #"{"type":"response_item","payload":{"type":"message","content":[{"text":"input_tokens: 999999"}]}}"#,
        #"{"timestamp":"broken","type":"event_msg","payload":{"type":"token_count"}}"#
    ])
    let costs = await f.estimator.summary(now: instant("2026-09-12T04:00:00Z"))
    #expect(costs.today.tokens == 295 && costs.today.requests == 3)
    #expect(abs((costs.today.usd ?? 0) - 0.505) < 0.0000001)
    #expect(costs.today.models["gpt-a"]?.tokens == 190)
    #expect(costs.today.models["gpt-b"]?.tokens == 105)
    #expect(costs.today.unknownModels.isEmpty)
}

@Test func localMondayWeekMayIncludePreviousMonth() async throws {
    let f = try CostFixture(); defer { f.clean() }
    try f.write([context(), usage("2026-08-30T15:00:00Z", 100), usage("2026-08-30T17:00:00Z", 200),
                 usage("2026-09-01T01:00:00Z", 300), usage("2026-09-02T16:30:00Z", 400)])
    let costs = await f.estimator.summary(now: instant("2026-09-03T04:00:00Z"))
    #expect(costs.today.tokens == 100 && costs.today.requests == 1)
    #expect(costs.week.tokens == 300 && costs.week.requests == 3)
    #expect(costs.month.tokens == 200 && costs.month.requests == 2)
    let nextWeek = await f.estimator.summary(now: instant("2026-09-07T04:00:00Z"))
    #expect(nextWeek.week.tokens == 0 && nextWeek.week.usd == nil)
    #expect(nextWeek.month.tokens == 200)
}

@Test func monthIncludesUsageBeforeCurrentWeekAndNestedAgents() async throws {
    let f = try CostFixture(); defer { f.clean() }
    try f.write([context(), usage("2026-09-01T01:00:00Z", 100)])
    try f.write([context(), usage("2026-09-12T01:00:00Z", 200)], name: "subagents/nested/agent.jsonl")
    try f.write([context(), usage("2026-09-13T01:00:00Z", 999)], name: "future.jsonl")
    let costs = await f.estimator.summary(now: instant("2026-09-12T04:00:00Z"))
    #expect(costs.today.tokens == 200 && costs.week.tokens == 200 && costs.month.tokens == 300)
}

@Test func forkReplayEstablishesBaselineButIsNotCounted() async throws {
    let f = try CostFixture(); defer { f.clean() }
    let fork = "2026-09-12T02:00:00Z"
    try f.write([context(), usage("2026-09-12T01:00:00Z", 200)], name: "parent.jsonl")
    try f.write([
        #"{"timestamp":"\#(fork)","type":"session_meta","payload":{"forked_from_id":"parent","timestamp":"\#(fork)"}}"#,
        context(),
        #"{"timestamp":"\#(fork)","type":"event_msg","payload":{"type":"task_started","started_at":\#(instant("2026-09-12T01:00:00Z").timeIntervalSince1970)}}"#,
        usage(fork, 200),
        #"{"timestamp":"\#(fork)","type":"event_msg","payload":{"type":"task_started","started_at":"\#(fork)"}}"#,
        usage("2026-09-12T03:00:00Z", 260)
    ], name: "fork.jsonl")
    let costs = await f.estimator.summary(now: instant("2026-09-12T04:00:00Z"))
    #expect(costs.today.tokens == 260 && costs.today.requests == 2)
}

@Test func priceFailuresRetryAndUnknownModelsKeepTokens() async throws {
    let f = try CostFixture([nil, "{}", testPrices]); defer { f.clean() }
    let now = instant("2026-09-12T04:00:00Z")
    try f.write([context(), usage("2026-09-12T03:00:00Z", 100)])
    for _ in 0..<2 {
        let cost = await f.estimator.summary(now: now).today
        #expect(cost.usd == nil && cost.tokens == 100 && cost.unknownModels == ["gpt-a"])
    }
    for _ in 0..<2 {
        let cost = await f.estimator.summary(now: now).today
        #expect(cost.usd == 0.1 && cost.unknownModels.isEmpty)
    }
    #expect(await f.replies.attempts == 3)
    try f.write([context("not-in-catalog"), usage("2026-09-12T03:00:00Z", 200)], name: "unknown.jsonl")
    let partial = await f.estimator.summary(now: now).today
    #expect(partial.usd == 0.1 && partial.tokens == 300 && partial.unknownModels == ["not-in-catalog"])
}

@Test func pricingLongContextAndMissingCategoryRates() async throws {
    let prices = #"{"long":{"litellm_provider":"openai","input_cost_per_token":0.001,"cache_read_input_token_cost":0.0001,"cache_creation_input_token_cost":0.002,"output_cost_per_token":0.01,"input_cost_per_token_above_272k_tokens":0.002,"cache_read_input_token_cost_above_272k_tokens":0.0002,"cache_creation_input_token_cost_above_272k_tokens":0.004,"output_cost_per_token_above_272k_tokens":0.02},"incomplete":{"litellm_provider":"openai","input_cost_per_token":0.001,"cache_read_input_token_cost":0.0001,"output_cost_per_token":0.01,"input_cost_per_token_above_272k_tokens":0.002},"no-write":{"litellm_provider":"openai","input_cost_per_token":0.001,"cache_read_input_token_cost":0.0001,"output_cost_per_token":0.01},"foreign":{"litellm_provider":"anthropic","input_cost_per_token":1,"cache_read_input_token_cost":1,"output_cost_per_token":1},"openai/slash":{"litellm_provider":"openai","input_cost_per_token":1,"cache_read_input_token_cost":1,"output_cost_per_token":1}}"#
    let f = try CostFixture([prices]); defer { f.clean() }
    let time = "2026-09-12T03:00:00Z"
    try f.write([context("long"), usage(time, 272_000)], name: "threshold.jsonl")
    try f.write([context("long"), usage(time, 300_000, cached: 20_000, write: 10_000, output: 100)], name: "long.jsonl")
    for model in ["incomplete", "no-write", "foreign", "openai/slash"] {
        try f.write([context(model), usage(time, 300_000, cached: 100, write: 10, output: 100)], name: model.replacingOccurrences(of: "/", with: "-") + ".jsonl")
    }
    let cost = await f.estimator.summary(now: instant("2026-09-12T04:00:00Z")).today
    #expect(cost.models["long"]?.usd == 858) // 272 + (540 ordinary + 4 cached + 40 write + 2 output).
    #expect(cost.unknownModels == ["incomplete", "no-write", "foreign", "openai/slash"])
    #expect(cost.requests == 6)
}

@Test func zeroCostNormalizationDoesNotTreatMissingPricesAsFree() async throws {
    let prices = #"{"free":{"litellm_provider":"openai","input_cost_per_token":0,"cache_read_input_token_cost":0,"output_cost_per_token":0}}"#
    let f = try CostFixture([prices]); defer { f.clean() }
    let now = instant("2026-09-12T04:00:00Z"), time = "2026-09-12T03:00:00Z"
    try f.write([context("free"), usage(time, 100)])
    #expect(await f.estimator.summary(now: now).today.usd == 0)
    try f.write([context("missing"), usage(time, 100)], name: "missing.jsonl")
    let cost = await f.estimator.summary(now: now).today
    #expect(cost.usd == nil && cost.tokens == 200 && cost.requests == 2)
    #expect(cost.models["free"]?.usd == 0 && cost.models["missing"]?.usd == nil)
}

@Test func fileCacheTracksSizeMtimeDeletionAndCutoff() async throws {
    let f = try CostFixture(); defer { f.clean() }
    let now = instant("2026-09-12T04:00:00Z"), time = "2026-09-12T03:00:00Z"
    try f.write([context(), usage(time, 100)])
    #expect(await f.estimator.summary(now: now).today.tokens == 100)
    try f.write([context(), usage(time, 200)]) // Same fingerprint deliberately retains cached parse.
    #expect(await f.estimator.summary(now: now).today.tokens == 100)
    try f.write([context(), usage(time, 200)], modified: now.addingTimeInterval(1))
    #expect(await f.estimator.summary(now: now).today.tokens == 200)
    try f.write([context(), usage(time, 200), usage(time, 350)], modified: now.addingTimeInterval(1))
    #expect(await f.estimator.summary(now: now).today.tokens == 350)
    try FileManager.default.removeItem(at: f.root.appendingPathComponent("usage.jsonl"))
    let deleted = await f.estimator.summary(now: now)
    #expect(deleted.today.tokens == 0 && deleted.today.usd == nil)
    try f.write([context(), usage(time, 500)])
    #expect(await f.estimator.summary(now: now).month.tokens == 500)
    #expect(await f.estimator.summary(now: instant("2026-10-01T04:00:00Z")).month.tokens == 0)
}

@Test func cacheWriteOnlyEventIsCountedAndCumulativeRegressionClampsEachField() async throws {
    let f = try CostFixture(); defer { f.clean() }
    let time = "2026-09-12T03:00:00Z"
    try f.write([context(), usage(time, 100, output: 10), usage(time, 100, write: 20, output: 10),
                 usage(time, 90, write: 20, output: 15)])
    let cost = await f.estimator.summary(now: instant("2026-09-12T04:00:00Z")).today
    #expect(cost.requests == 3 && cost.tokens == 115)
    #expect(abs((cost.usd ?? 0) - 0.29) < 0.0000001)
}

@Test func forkFractionalTimestampAcceptsSecondPrecisionTaskStart() async throws {
    let f = try CostFixture(); defer { f.clean() }
    let start = instant("2026-09-12T02:00:00Z").timeIntervalSince1970
    try f.write([
        #"{"timestamp":"2026-09-12T02:00:00.900Z","type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
        context(), usage("2026-09-12T01:00:00Z", 100),
        #"{"type":"event_msg","payload":{"type":"task_started","started_at":\#(start)}}"#,
        usage("2026-09-12T03:00:00Z", 120)
    ])
    let cost = await f.estimator.summary(now: instant("2026-09-12T04:00:00Z")).today
    #expect(cost.requests == 1 && cost.tokens == 20)
}

@Test func extremeExternalTokenCountersCannotOverflowTotalsOrPricing() async throws {
    let f = try CostFixture(); defer { f.clean() }
    let time = "2026-09-12T03:00:00Z", now = instant("2026-09-12T04:00:00Z")
    try f.write([context(), usage(time, Int.max, output: 1), usage(time, 100)])
    let valid = await f.estimator.summary(now: now).today
    #expect(valid.tokens == 100 && valid.requests == 1 && valid.usd == 0.1)

    try f.write([context(), usage(time, 1, cached: Int.max, write: Int.max)], name: "cache.jsonl")
    try f.write([context(), usage(time, Int.max)], name: "huge.jsonl")
    let bounded = await f.estimator.summary(now: now).today
    #expect(bounded.tokens == Int.max && bounded.models["gpt-a"]?.tokens == Int.max)
    #expect(bounded.requests == 3 && bounded.unknownModels.isEmpty)
    #expect(bounded.usd?.isFinite == true)
}
