import Foundation
import Testing
@testable import CookedCore

private actor Replies {
    private var replies: [(Int, String, String?)]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [(Int, String, String?)]) { self.replies = replies }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        let (status, body, retry) = replies.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                              headerFields: retry.map { ["Retry-After": $0] })!)
    }
}

private let quotaJSON = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":14,"reset_at":2000000000},"secondary_window":{"used_percent":70}},"spend_control":{"individual_limit":{"used":3,"limit":10}}}"#

private struct ProviderFixture {
    let home: URL
    let replies: Replies
    let provider: CodexProvider
    init(_ replies: [(Int, String, String?)], authenticated: Bool = true) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        self.replies = Replies(replies)
        let responder = self.replies
        let catalog = PriceCatalog(http: HTTPClient { request in
            (Data(#"{"gpt-test":{"litellm_provider":"openai","input_cost_per_token":0.01,"cache_read_input_token_cost":0.005,"output_cost_per_token":0.02}}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        provider = CodexProvider(home: home, http: HTTPClient { try await responder.send($0) },
                                 estimator: CostEstimator(root: home.appendingPathComponent("sessions"), catalog: catalog))
        if authenticated { try login() }
    }
    func login() throws {
        try Data(#"{"tokens":{"access_token":"fixture-token","account_id":"fixture-account"}}"#.utf8)
            .write(to: home.appendingPathComponent("auth.json"))
    }
    func clean() { try? FileManager.default.removeItem(at: home) }
    func addUsage(now: Date) throws {
        let time = ISO8601DateFormatter().string(from: now)
        let text = """
        {"timestamp":"\(time)","type":"turn_context","payload":{"model":"gpt-test"}}
        {"timestamp":"\(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}
        """
        try Data(text.utf8).write(to: home.appendingPathComponent("sessions/usage.jsonl"))
    }
}

@Test func httpStatusCacheTimeoutAndRetryBoundaries() async throws {
    for (raw, expected) in [("30", 30.0), ("nonsense", 300), ("-2", 300), ("nan", 300), ("1e308", 604_800), ("1e309", 300)] {
        let replies = Replies([(429, "", raw)])
        let client = HTTPClient { try await replies.send($0) }
        var request = URLRequest(url: URL(string: "https://example.invalid")!)
        request.timeoutInterval = 5
        await #expect(throws: HTTPError.rateLimited(expected)) { try await client.data(for: request) }
        let sent = await replies.requests
        #expect(sent[0].cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(sent[0].httpShouldHandleCookies == false)
        #expect(sent[0].timeoutInterval == 5)
    }
    let replies = Replies([(403, "", nil), (200, "ok", nil)])
    let client = HTTPClient { try await replies.send($0) }
    let request = URLRequest(url: URL(string: "https://example.invalid")!)
    await #expect(throws: HTTPError.status(403)) { try await client.data(for: request) }
    #expect(try await client.data(for: request) == Data("ok".utf8))
    let sent = await replies.requests
    #expect(sent[0].timeoutInterval == 15)
}

@Test func httpRedirectsStayOnOriginalOriginAndPreserveExplicitCredentials() async throws {
    let original = URL(string: "https://example.invalid/usage")!
    var request = URLRequest(url: original)
    request.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
    request.setValue("session=fixture-cookie", forHTTPHeaderField: "Cookie")
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: request)
    defer { task.cancel(); session.invalidateAndCancel() }
    let delegate = SameOriginRedirectDelegate()
    let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!
    for (destination, allowed) in [
        ("https://example.invalid/other?updated=1", true),
        ("https://EXAMPLE.invalid:443/usage", true),
        ("https://other.invalid/usage", false),
        ("https://sub.example.invalid/usage", false),
        ("https://example.invalid:444/usage", false),
        ("http://example.invalid/usage", false),
        ("https://fixture-user@example.invalid/usage", false)
    ] {
        var redirected = request
        redirected.url = URL(string: destination)!
        let result: URLRequest? = await withCheckedContinuation { continuation in
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) {
                continuation.resume(returning: $0)
            }
        }
        #expect((result != nil) == allowed)
        if allowed {
            #expect(result?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            #expect(result?.value(forHTTPHeaderField: "Cookie") == "session=fixture-cookie")
        }
    }
    #expect(SameOriginRedirectDelegate.allowsRedirect(from: URL(string: "http://example.invalid"), to: URL(string: "http://example.invalid:80/usage")))
    #expect(!SameOriginRedirectDelegate.allowsRedirect(from: nil, to: original))
    #expect(!SameOriginRedirectDelegate.allowsRedirect(from: original, to: nil))

    let replies = Replies([(200, "ok", nil)])
    _ = try await HTTPClient { try await replies.send($0) }.data(for: request)
    let sent = await replies.requests
    #expect(sent[0].httpShouldHandleCookies == false)
    #expect(sent[0].value(forHTTPHeaderField: "Cookie") == "session=fixture-cookie")
}

@Test func httpRetryAfterDatesRespectServerDeadlineAndBounds() async throws {
    let now = ISO8601DateFormatter().date(from: "1994-11-06T08:48:00Z")!
    for value in ["Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994"] {
        #expect(HTTPClient.retryDelay(value, now: now) == 97)
    }
    #expect(HTTPClient.retryDelay("Sun, 06 Nov 1994 08:47:59 GMT", now: now) == 0)
    #expect(HTTPClient.retryDelay("Sun, 20 Nov 1994 08:49:37 GMT", now: now) == 604_800)
    #expect(HTTPClient.retryDelay("Sun, 99 Nov 1994 08:49:37 GMT", now: now) == 300)
    #expect(HTTPClient.retryDelay(nil, now: now) == 300)

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    let replies = Replies([(429, "", formatter.string(from: Date().addingTimeInterval(1_209_600)))])
    let client = HTTPClient { try await replies.send($0) }
    await #expect(throws: HTTPError.rateLimited(604_800)) {
        try await client.data(for: URLRequest(url: URL(string: "https://example.invalid/usage")!))
    }
}

@Test func commandDrainsPipesAndHonorsTimeout() {
    #expect(Command.output("/usr/bin/printf", ["你好\n"]) == "你好")
    #expect(Command.output("/bin/sh", ["-c", "exit 1"]) == nil)
    #expect(Command.output("/not/a/command", []) == nil)
    #expect(Command.output("/usr/bin/awk", [#"BEGIN { for (i=0;i<20000;i++) print "0123456789" }"#])?.count == 219_999)
    #expect(Command.output("/bin/sh", ["-c", "sleep 0.02; printf final-output"]) == "final-output")
    let start = ProcessInfo.processInfo.systemUptime
    #expect(Command.output("/bin/sleep", ["2"], timeout: 0.05) == nil)
    #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    let inherited = ProcessInfo.processInfo.systemUptime
    #expect(Command.output("/bin/sh", ["-c", "sleep 2 & printf done"]) == "done")
    #expect(ProcessInfo.processInfo.systemUptime - inherited < 1)
    let streaming = ProcessInfo.processInfo.systemUptime
    // Closing the read pipe makes the inherited writer exit on SIGPIPE.
    _ = Command.output("/bin/sh", ["-c", "yes &"], timeout: 0.05)
    #expect(ProcessInfo.processInfo.systemUptime - streaming < 1)
}

@Test func codexDecodesQuotaAndUsesReadonlyCredentials() async throws {
    let fixture = try ProviderFixture([(200, quotaJSON, nil)])
    defer { fixture.clean() }
    let original = try Data(contentsOf: fixture.home.appendingPathComponent("auth.json"))
    let snapshot = try #require(await fixture.provider.fetch(now: Date()))
    #expect(snapshot.title == "Codex" && snapshot.subtitle == "Plus")
    #expect(snapshot.metrics.map(\.label) == ["Current window", "Weekly window", "Monthly credits"])
    #expect(snapshot.metrics.map(\.progress) == [0.14, 0.7, 0.3])
    #expect(snapshot.metrics[2].value == "30% · 3 / 10 cr")
    #expect(snapshot.notes.isEmpty && snapshot.monthUSD == nil)
    let requests = await fixture.replies.requests
    #expect(requests[0].url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
    #expect(requests[0].value(forHTTPHeaderField: "chatgpt-account-id") == "fixture-account")
    #expect(try Data(contentsOf: fixture.home.appendingPathComponent("auth.json")) == original)
}

@Test func codexRetainsLastGoodAcrossFailuresAndCredentialsLoss() async throws {
    let fixture = try ProviderFixture([(200, quotaJSON, nil), (200, "{}", nil), (500, "", nil), (401, "", nil)])
    defer { fixture.clean() }
    let now = Date()
    for i in 0..<5 {
        let snapshot = try #require(await fixture.provider.fetch(now: now.addingTimeInterval(Double(i * 60))))
        #expect(snapshot.metrics.count == 3)
        #expect(snapshot.notes.isEmpty == (i == 0))
        if i == 3 { #expect(snapshot.notes.first?.contains("codex login") == true) }
    }
    try FileManager.default.removeItem(at: fixture.home.appendingPathComponent("auth.json"))
    let cached = try #require(await fixture.provider.fetch(now: now.addingTimeInterval(300)))
    #expect(cached.metrics.count == 3)
    #expect(await fixture.replies.requests.count == 5)
}

@Test func codexWaitsForRetryAfterAndRecovers() async throws {
    let fixture = try ProviderFixture([(200, quotaJSON, nil), (429, "", "120"), (200, quotaJSON, nil)])
    defer { fixture.clean() }
    let now = Date()
    _ = await fixture.provider.fetch(now: now)
    let limited = try #require(await fixture.provider.fetch(now: now.addingTimeInterval(60)))
    #expect(limited.metrics.count == 3 && limited.notes == ["retry in 2m"])
    let waiting = try #require(await fixture.provider.fetch(now: now.addingTimeInterval(119)))
    #expect(waiting.metrics.count == 3)
    #expect(await fixture.replies.requests.count == 2)
    let recovered = try #require(await fixture.provider.fetch(now: now.addingTimeInterval(180)))
    #expect(recovered.notes.isEmpty)
    #expect(await fixture.replies.requests.count == 3)
}

@Test func codexBoundsMalformedAndHugeBackoffWithoutImmediateRequests() async throws {
    for retry in ["invalid", "1e308"] {
        let fixture = try ProviderFixture([(429, "", retry)])
        defer { fixture.clean() }
        let now = Date()
        let first = try #require(await fixture.provider.fetch(now: now))
        #expect(first.metrics.isEmpty && !first.notes.isEmpty)
        _ = await fixture.provider.fetch(now: now.addingTimeInterval(60))
        #expect(await fixture.replies.requests.count == 1)
    }
}

@Test func codexHidesUnavailableQuotaButKeepsLocalUsage() async throws {
    let missing = try ProviderFixture([], authenticated: false)
    defer { missing.clean() }
    let now = Date()
    #expect(await missing.provider.fetch(now: now) == nil)
    try missing.addUsage(now: now)
    let local = try #require(await missing.provider.fetch(now: now))
    #expect(local.monthTokens == 110 && local.monthRequests == 1)
    #expect(local.metrics.count == 3 && local.details.count == 1)
    #expect(local.metrics.allSatisfy { $0.period != nil && $0.progress == nil })
    #expect(await missing.replies.requests.isEmpty)
    for status in [403, 404] {
        let denied = try ProviderFixture([(200, quotaJSON, nil), (status, "", nil), (status, "", nil)])
        defer { denied.clean() }
        _ = await denied.provider.fetch(now: now)
        #expect(await denied.provider.fetch(now: now)?.metrics.count == 3)
        try denied.addUsage(now: now)
        let local = try #require(await denied.provider.fetch(now: now))
        #expect(local.monthRequests == 1 && local.metrics.count == 6)
        #expect(local.metrics.filter { $0.progress != nil }.count == 3)
    }
}

@Test func codexLoginFailureAndTransientFailureHaveUsefulNotes() async throws {
    for status in [404, 500, 200] {
        let fixture = try ProviderFixture([(status, "{}", nil)])
        defer { fixture.clean() }
        let snapshot = try #require(await fixture.provider.fetch(now: Date()))
        #expect(snapshot.metrics.isEmpty && !snapshot.notes.isEmpty)
    }
}

@Test func codexWithoutQuotaKeepsAccountMetadata() async throws {
    let f = try ProviderFixture([(200, #"{"plan_type":"plus","credits":{"has_credits":true}}"#, nil)])
    defer { f.clean() }
    let snapshot = try #require(await f.provider.fetch(now: Date()))
    #expect(snapshot.subtitle == "Plus")
    #expect(snapshot.metrics.isEmpty)
    #expect(snapshot.notes.first == "Limits unavailable; Codex auth or usage API missing.")
    #expect(snapshot.notes.contains("Credits are workspace units, not USD."))
}

@Test func codexCreditsAreWorkspaceUnitsAndSupportUtilizationAndReset() async throws {
    let json = #"{"rate_limit":{"primary_window":{"utilization":12}},"credits":{"has_credits":true},"spend_control":{"individual_limit":{"used":1200,"limit":5000,"reset_at":2000000000}}}"#
    let f = try ProviderFixture([(200, json, nil)]); defer { f.clean() }
    let snapshot = try #require(await f.provider.fetch(now: Date()))
    #expect(snapshot.metrics[0].value == "12%")
    #expect(snapshot.metrics[1].value == "24% · 1.2K / 5.0K cr")
    #expect(snapshot.metrics[1].detail?.hasPrefix("reset ") == true)
    #expect(snapshot.notes == ["Credits are workspace units, not USD."])
    #expect(snapshot.monthUSD == nil)
}

@Test func rejectedCodexCredentialsWithoutQuotaOrLogsAreHidden() async throws {
    for status in [401, 403] {
        let f = try ProviderFixture([(status, "", nil)]); defer { f.clean() }
        #expect(await f.provider.fetch(now: Date()) == nil)
    }
}
