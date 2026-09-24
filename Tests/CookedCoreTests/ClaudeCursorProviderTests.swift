import Foundation
import Testing
@testable import CookedCore

private actor ProviderReplies {
    var replies: [(Int, String)]
    var requests: [URLRequest] = []
    init(_ replies: [(Int, String)]) { self.replies = replies }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        let (status, body) = replies.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "120"])!)
    }
}

private func providerHome(_ path: String) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
    return home
}
private let claudeToken = #"{"claudeAiOauth":{"accessToken":"fixture-token"}}"#
private let claudeQuota = #"{"five_hour":{"utilization":25,"resets_at":"2026-09-25T00:00:00Z"},"seven_day":{"utilization":80},"seven_day_opus":null,"extra_usage":{"is_enabled":false}}"#
private let cursorDB = "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
private func cursorToken() -> String {
    let payload = Data(#"{"sub":"auth0|user_fixture"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return "header.\(payload).signature"
}

@Test func missingProvidersDoNotReadCredentialsOrCallNetwork() async {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let command: CredentialCommand = { _, _ in Issue.record("Unexpected credential read"); return nil }
    let http = HTTPClient { _ in Issue.record("Unexpected network call"); throw URLError(.notConnectedToInternet) }
    #expect(await ClaudeProvider(home: home, http: http, command: command).fetch(now: Date()) == nil)
    #expect(await CursorProvider(home: home, http: http, command: command).fetch(now: Date()) == nil)
}

@Test func claudeQuotaHeadersBackoffAndExpiredLogin() async throws {
    let home = try providerHome(".claude")
    defer { try? FileManager.default.removeItem(at: home) }
    try Data(#"{"oauthAccount":{"organizationName":"Fixture org","seatTier":"max"}}"#.utf8).write(to: home.appendingPathComponent(".claude.json"))
    let replies = ProviderReplies([(200, claudeQuota), (429, ""), (401, "")])
    let provider = ClaudeProvider(home: home, http: HTTPClient { try await replies.send($0) }, command: { executable, arguments in
        #expect(executable == "/usr/bin/security")
        #expect(arguments == ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        return claudeToken
    })
    let now = Date()
    let first = try #require(await provider.fetch(now: now))
    #expect(first.subtitle == "max")
    #expect(first.metrics.map(\.progress) == [0.25, 0.8])
    #expect(first.monthUSD == nil)
    let requests = await replies.requests
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
    #expect(requests[0].value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    _ = await provider.fetch(now: now.addingTimeInterval(60))
    let cached = try #require(await provider.fetch(now: now.addingTimeInterval(90)))
    #expect(cached.metrics.count == 2 && cached.notes[0].contains("previous usage"))
    #expect(await replies.requests.count == 2)
    let expired = try #require(await provider.fetch(now: now.addingTimeInterval(180)))
    #expect(expired.notes[0].contains("sign in") || expired.notes[0].contains("Sign in"))
}

@Test func cursorAllowancePriorityCentsAndReadonlyCookie() async throws {
    let home = try providerHome("Library/Application Support/Cursor/User/globalStorage")
    defer { try? FileManager.default.removeItem(at: home) }
    try Data().write(to: home.appendingPathComponent(cursorDB))
    for (individual, pooled, expected, progress) in [
        (#"{"used":500,"limit":2000}"#, #"{"used":700,"limit":1000}"#, "Individual allowance", 0.25),
        (#"{"used":0,"limit":0}"#, #"{"used":700,"limit":1000}"#, "Team pooled allowance", 0.7),
        ("null", "null", "Team on-demand", 0.1)
    ] {
        let body = #"{"membershipType":"pro","billingCycleEnd":"2026-10-01T00:00:00Z","individualUsage":{"overall":\#(individual)},"teamUsage":{"pooled":\#(pooled),"onDemand":{"used":100,"limit":1000}}}"#
        let replies = ProviderReplies([(200, body), (401, "")])
        let provider = CursorProvider(home: home, http: HTTPClient { try await replies.send($0) }, command: { executable, arguments in
            #expect(executable == "/usr/bin/sqlite3" && arguments.first == "-readonly")
            #expect(arguments[1] == home.appendingPathComponent(cursorDB).path)
            return cursorToken()
        })
        let snapshot = try #require(await provider.fetch(now: Date()))
        #expect(snapshot.metrics[0].label == expected && snapshot.metrics[0].progress == progress)
        #expect(snapshot.metrics[0].value.contains(Format.cost(expected == "Individual allowance" ? 5 : expected == "Team pooled allowance" ? 7 : 1)))
        #expect(snapshot.monthUSD == nil && snapshot.todayUSD == nil)
        #expect(snapshot.metrics[0].detail?.hasPrefix("reset") == true)
        let requests = await replies.requests
        #expect(requests[0].value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=user_fixture::\(cursorToken())")
        #expect(await provider.fetch(now: Date())?.notes[0].contains("Reopen Cursor") == true)
    }
}

@Test func installedButInvalidCredentialsRemainVisibleWithoutHTTP() async throws {
    let home = try providerHome(".claude")
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home.appendingPathComponent(cursorDB).deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: home.appendingPathComponent(cursorDB))
    let http = HTTPClient { _ in Issue.record("Unexpected network call"); throw URLError(.notConnectedToInternet) }
    let claude = ClaudeProvider(home: home, http: http, command: { _, _ in "{}" })
    let cursor = CursorProvider(home: home, http: http, command: { _, _ in "malformed" })
    #expect(await claude.fetch(now: Date())?.notes.first?.contains("credentials unavailable") == true)
    #expect(await cursor.fetch(now: Date())?.notes.first?.contains("credentials unavailable") == true)
}

@Test func claudeCostCacheTokensDedupAndUnknownModels() async throws {
    let home = try providerHome(".claude/projects/nested")
    defer { try? FileManager.default.removeItem(at: home) }
    let now = Date(), time = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-1))
    let record = #"{"type":"assistant","timestamp":"\#(time)","requestId":"r1","message":{"id":"m1","model":"claude-test","content":[{"text":"ignored"}],"usage":{"input_tokens":100,"cache_read_input_tokens":20,"cache_creation_input_tokens":10,"output_tokens":5}}}"#
    let unknown = #"{"type":"assistant","timestamp":"\#(time)","message":{"id":"m2","model":"claude-unknown","usage":{"input_tokens":10,"output_tokens":1}}}"#
    let root = home.appendingPathComponent(".claude/projects")
    try Data((record + "\n" + record + "\n" + unknown + "\ninvalid\n").utf8).write(to: root.appendingPathComponent("a.jsonl"))
    try Data(record.utf8).write(to: root.appendingPathComponent("nested/replay.jsonl"))
    let catalog = PriceCatalog(http: HTTPClient { request in
        (Data(#"{"claude-test":{"litellm_provider":"anthropic","input_cost_per_token":0.001,"cache_read_input_token_cost":0.0001,"cache_creation_input_token_cost":0.002,"output_cost_per_token":0.01}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let estimator = CostEstimator(root: root, catalog: catalog, source: .claude)
    let costs = await estimator.summary(now: now)
    #expect(costs.month.tokens == 146 && costs.month.requests == 2)
    #expect(abs((costs.month.usd ?? 0) - 0.172) < 0.000001)
    #expect(costs.month.unknownModels == ["claude-unknown"])
    let provider = ClaudeProvider(home: home, estimator: estimator, command: { _, _ in nil })
    let snapshot = try #require(await provider.fetch(now: now))
    #expect(snapshot.notes.contains { $0.contains("unknown price") })
    #expect(snapshot.notes.contains { $0.contains("this Mac") })
    #expect(snapshot.details.count == 2)
}

@Test func cursorSchemaFailuresBackoffAndRecoveryKeepPreviousUsage() async throws {
    let home = try providerHome("Library/Application Support/Cursor/User/globalStorage")
    defer { try? FileManager.default.removeItem(at: home) }
    try Data().write(to: home.appendingPathComponent(cursorDB))
    let quota = #"{"individualUsage":{"plan":{"used":500,"limit":1000}}}"#
    let replies = ProviderReplies([(200, quota), (200, "{}"), (200, #"{"individualUsage":42}"#), (500, ""), (429, ""), (200, quota)])
    let provider = CursorProvider(home: home, http: HTTPClient { try await replies.send($0) }, command: { _, _ in cursorToken() })
    let now = Date()
    for index in 0..<5 {
        let snapshot = try #require(await provider.fetch(now: now.addingTimeInterval(Double(index * 60))))
        #expect(snapshot.metrics.first?.progress == 0.5)
        #expect(snapshot.notes.isEmpty == (index == 0))
    }
    _ = await provider.fetch(now: now.addingTimeInterval(300))
    #expect(await replies.requests.count == 5)
    #expect(await provider.fetch(now: now.addingTimeInterval(360))?.notes.isEmpty == true)
    try FileManager.default.removeItem(at: home.appendingPathComponent(cursorDB))
    #expect(await provider.fetch(now: now.addingTimeInterval(420)) == nil)
}

@Test func claudeLongContextAndHourCacheUseDistinctPrices() async throws {
    let home = try providerHome("logs")
    defer { try? FileManager.default.removeItem(at: home) }
    let time = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-1))
    let rows = """
    {"type":"assistant","timestamp":"\(time)","message":{"id":"long","model":"claude-test","usage":{"input_tokens":200001,"cache_creation_input_tokens":5,"cache_creation":{"ephemeral_1h_input_tokens":5},"output_tokens":1}}}
    {"type":"assistant","timestamp":"\(time)","message":{"id":"hour","model":"claude-test","usage":{"input_tokens":1,"cache_creation_input_tokens":10,"cache_creation":{"ephemeral_1h_input_tokens":5},"output_tokens":1}}}
    """
    let root = home.appendingPathComponent("logs")
    try Data(rows.utf8).write(to: root.appendingPathComponent("usage.jsonl"))
    let prices = #"{"claude-test":{"litellm_provider":"anthropic","input_cost_per_token":0.001,"cache_read_input_token_cost":0.0001,"cache_creation_input_token_cost":0.002,"cache_creation_input_token_cost_above_1hr":0.004,"output_cost_per_token":0.01,"input_cost_per_token_above_200k_tokens":0.002,"output_cost_per_token_above_200k_tokens":0.02,"cache_creation_input_token_cost_above_1hr_above_200k_tokens":0.008}}"#
    let catalog = PriceCatalog(http: HTTPClient { request in
        (Data(prices.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let result = await CostEstimator(root: root, catalog: catalog, source: .claude).summary(now: Date())
    #expect(result.month.requests == 2 && result.month.tokens == 200019)
    #expect(abs((result.month.usd ?? 0) - 400.103) < 0.000001)
    #expect(result.month.unknownModels.isEmpty)
}

@Test func claudeMalformedWindowsDoNotCrashOrDisappear() async throws {
    let home = try providerHome(".claude")
    defer { try? FileManager.default.removeItem(at: home) }
    for body in [#"{"five_hour":42}"#, #"{"five_hour":{"utilization":"changed"}}"#, "{}"] {
        let replies = ProviderReplies([(200, body)])
        let provider = ClaudeProvider(home: home, http: HTTPClient { try await replies.send($0) }, command: { _, _ in claudeToken })
        let snapshot = try #require(await provider.fetch(now: Date()))
        #expect(snapshot.metrics.isEmpty && snapshot.notes[0].contains("Usage API"))
    }
}
