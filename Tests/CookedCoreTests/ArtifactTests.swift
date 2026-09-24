import XCTest
import ImageIO
@testable import CookedCore

final class ArtifactTests: XCTestCase {
    func testRepresentativeFramesAndCards() throws {
        let now = ReleaseDates.parse("2026-09-24")!.addingTimeInterval(6 * 3600)
        let companies = ModelCompany.configured()
        var catalog = try ModelCatalog.decode(metadata: Data(#"""
        {"openai/luna":{"name":"GPT-6 Luna","release_date":"2026-09-22","description":"A compact model for coding and multimodal reasoning.","knowledge":"2026-06","limit":{"context":1050000,"output":128000},"modalities":{"input":["text","image"],"output":["text"]},"benchmarks":[{"name":"Terminal-Bench","score":84.7,"harness":"agent-v1"},{"name":"SWE-Bench Pro","score":62.7}]},
        "openai/sol":{"name":"GPT-6 Sol","release_date":"2026-09-22","description":"A capable general-purpose model for long-running tasks.","limit":{"context":1000000,"output":128000},"benchmarks":[{"name":"Terminal-Bench","score":82.2,"harness":"agent-v1"}]},
        "google/flash":{"name":"Gemini Flash","release_date":"2026-09-21","limit":{"context":1048576,"output":65536},"benchmarks":[{"name":"Terminal-Bench","score":80.1,"harness":"agent-v1"}]},
        "openai/previous":{"name":"GPT Previous","release_date":"2026-09-01"},"openai/older":{"name":"GPT Older","release_date":"2026-08-11"}}
        """#.utf8), prices: Data(#"""
        {"openai":{"name":"OpenAI","models":{"luna":{"cost":{"input":0.2,"output":1.2,"cache_read":0.02,"cache_write":0.25}},"sol":{"cost":{"input":4,"output":20,"cache_read":0.2,"cache_write":5}}}},
        "google":{"name":"Google","models":{"flash":{"cost":{"input":0.75,"output":3.75,"cache_read":0.075}}}},
        "amazon-bedrock":{"models":{"us.openai.luna-v1:0":{"name":"GPT-6 Luna"}}}}
        """#.utf8), companies: companies, now: now)
        let snapshots = [ProviderSnapshot(title: "Codex", subtitle: "Plus", todayUSD: 1.05, weekUSD: 8.76, monthUSD: 27.45,
            monthTokens: 22_000_000, monthRequests: 640,
            metrics: [Metric("Current window", "8%", progress: 0.08, detail: "reset 18:46"),
                      Metric("Weekly window", "27%", progress: 0.27, detail: "reset Sun 12:46"),
                      Metric("Today", "$1.05", period: .today, detail: "1.9M tokens · 31 requests"),
                      Metric("This week", "$8.76", period: .week, detail: "7.0M tokens · 210 requests"),
                      Metric("This month", "$27.45", period: .month, detail: "22.0M tokens · 640 requests")],
            details: [Metric("GPT 6 Luna", "$25.10", detail: "20.1M tokens · 590 req"), Metric("GPT 6 Sol", "$2.35", detail: "1.9M tokens · 50 req")])]
        var timeline = TimelineState(); timeline.reconcile(models: TimelineRenderer.models(catalog: catalog, companies: companies))
        let home = TimelineRenderer.frame(catalog: catalog, companies: companies, state: timeline, now: now, rows: 31, columns: 102, loading: false, color: false).text
        let usage = DashboardRenderer.render(snapshots: snapshots, now: now, live: true, expanded: true, maxRows: 30, maxColumns: 82, notice: nil, loading: false, color: false, newModels: true)
        XCTAssertTrue(usage.contains("Models NEW")); XCTAssertTrue(usage.contains("This month")); XCTAssertTrue(usage.contains("640 requests"))
        var comparison = ModelCompareState(); comparison.searching = false; comparison.selectedIDs = ["openai/sol", "openai/luna", "google/flash"]
        let compare = ModelCompareRenderer.frame(catalog: catalog, state: comparison, rows: 31, columns: 106, color: false, now: now).text
        XCTAssertTrue(compare.contains("Cache write $/1M")); XCTAssertTrue(compare.contains("-95%")); XCTAssertTrue(home.contains("NEW"))
        let modelCard = try ModelShareCard.png(catalog: catalog, companies: companies, timeline: timeline, now: now)
        let usageCard = try ShareCardRenderer.png(snapshots: snapshots, now: now, name: "local-user")
        let compareCard = try ModelShareCard.png(catalog: catalog, companies: companies, timeline: timeline, comparison: comparison, now: now)
        let labCard = try ModelShareCard.png(catalog: catalog, companies: companies, timeline: timeline, companyCard: true, now: now)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(usageCard as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil)); XCTAssertEqual(image.width, 960)
        // Card height follows the rendered rows and spacing.
        XCTAssertEqual(image.height, 1020)
        if let path = ProcessInfo.processInfo.environment["COOKED_RENDER_ARTIFACTS"] {
            let dir = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, data) in [("usage.png", usageCard), ("model.png", modelCard), ("compare.png", compareCard), ("lab.png", labCard)] { try data.write(to: dir.appendingPathComponent(name)) }
            for (name, text) in [("usage.txt", usage), ("home.txt", home), ("compare.txt", compare)] { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
            let logo = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><path d="M2 2H22V22H2Z" fill="currentColor"/></svg>"#.utf8)
            try ModelShareCard.png(catalog: catalog, companies: companies, timeline: timeline, mark: logo, now: now).write(to: dir.appendingPathComponent("marked.png"))
            timeline.handle(.next, models: TimelineRenderer.models(catalog: catalog, companies: companies), scrollLimit: 0)
            try Data(TimelineRenderer.frame(catalog: catalog, companies: companies, state: timeline, now: now, rows: 31, columns: 102, loading: false, color: false).text.utf8).write(to: dir.appendingPathComponent("company.txt"))
            catalog.priceError = "offline"
            try ModelShareCard.png(catalog: catalog, companies: companies, timeline: timeline, now: now).write(to: dir.appendingPathComponent("prices-incomplete.png"))
        }
    }
}
