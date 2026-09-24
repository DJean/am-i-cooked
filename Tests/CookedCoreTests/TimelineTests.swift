import XCTest
@testable import CookedCore

final class TimelineTests: XCTestCase {
    let now = ReleaseDates.parse("2026-09-24")!
    let companies = [ModelCompany(id: "openai", name: "OpenAI", priceSources: ["openai"])]
    func fixture() throws -> ModelCatalog {
        try ModelCatalog.decode(metadata: Data(#"""
        {"openai/new":{"name":"GPT 6 Luna","release_date":"2026-09-23","description":"A model for coding and reasoning.","limit":{"context":1048576,"output":128000},"modalities":{"input":["text","image"],"output":["text"]},"knowledge":"2026-06","last_updated":"2026-09-24","benchmarks":[{"name":"Eval","score":82}]},
         "openai/peer":{"name":"GPT 6 Sol","release_date":"2026-09-23"},
         "openai/old":{"name":"Old model","release_date":"2026-09-01"},
         "openai/month":{"name":"Month only","release_date":"2026-08"}}
        """#.utf8), prices: nil, companies: companies, now: now)
    }
    func frame(_ catalog: ModelCatalog, _ state: TimelineState, rows: Int = 31, columns: Int = 102, color: Bool = false) -> TimelineFrame {
        TimelineRenderer.frame(catalog: catalog, companies: companies, state: state, now: now, rows: rows, columns: columns, loading: false, color: color)
    }
    func testBatchHistoryFactsAndNewWindow() throws {
        let catalog = try fixture(), models = TimelineRenderer.models(catalog: catalog, companies: companies)
        let groups = TimelineRelease.grouped(models: models)
        XCTAssertEqual(groups.count, 3); XCTAssertEqual(groups[0].models.count, 2)
        XCTAssertEqual(groups[0].summary, "GPT 6 Luna / Sol")
        let text = frame(catalog, TimelineState(), rows: 50).text
        for value in ["AM I COOKED?", "Usage", "Models", "NEW", "23 days ago", "1M context", "128K output", "text · image → text", "knows to 2026-06", "refreshed", "2026-09-24", "Source", "Cache write", "BENCHMARKS"] { XCTAssertTrue(text.contains(value), value) }
        XCTAssertFalse(text.contains("Month only")) // Month-only models belong on company pages, not dated batches.
        XCTAssertTrue(models[0].isNewRelease(now: now)); XCTAssertFalse(models[0].isNewRelease(now: now.addingTimeInterval(-172800)))
        XCTAssertEqual(TimelineRenderer.age(models[0].exactDate, now: now), "1 day ago")
    }
    func testNavigationHasNoFocusAndReturnsToOrigin() throws {
        let catalog = try fixture(), models = TimelineRenderer.models(catalog: catalog, companies: companies)
        var state = TimelineState(); state.reconcile(models: models)
        state.handle(.down, models: models, scrollLimit: 0)
        XCTAssertEqual(state.selectedID, "openai/old")
        let home = state.releaseID
        state.handle(.next, models: models, scrollLimit: 0)
        XCTAssertTrue(state.isCompanyPage); XCTAssertEqual(state.selectedID, "openai/old")
        state.handle(.text("J"), models: models, scrollLimit: 0)
        XCTAssertEqual(state.selectedID, "openai/month")
        state.handle(.text("K"), models: models, scrollLimit: 0)
        XCTAssertEqual(state.selectedID, "openai/old")
        state.handle(.previous, models: models, scrollLimit: 0)
        XCTAssertFalse(state.isCompanyPage); XCTAssertEqual(state.releaseID, home); XCTAssertEqual(state.selectedID, "openai/old")
    }
    func testDetailPagesWrapAndKeepTitlePinned() throws {
        var catalog = try fixture()
        let index = try XCTUnwrap(catalog.models.firstIndex { $0.id == "openai/new" })
        catalog.models[index].benchmarks = (0..<80).map { ModelBenchmark(name: "Benchmark \($0)", score: Double($0)) }
        let models = TimelineRenderer.models(catalog: catalog, companies: companies)
        var state = TimelineState(); state.reconcile(models: models)
        let first = frame(catalog, state, rows: 21)
        XCTAssertGreaterThan(first.scrollLimit, 0)
        state.handle(.toggle, models: models, scrollLimit: first.scrollLimit, paneRows: 15)
        XCTAssertEqual(state.detailOffset, 13)
        let paged = frame(catalog, state, rows: 21).text
        XCTAssertTrue(paged.contains("GPT 6 Luna")); XCTAssertNotEqual(first.text, paged)
        for _ in 0..<100 where state.detailOffset < first.scrollLimit { state.handle(.toggle, models: models, scrollLimit: first.scrollLimit, paneRows: 15) }
        XCTAssertEqual(state.detailOffset, first.scrollLimit)
        state.handle(.toggle, models: models, scrollLimit: first.scrollLimit, paneRows: 15)
        XCTAssertEqual(state.detailOffset, 0)
    }
    func testRefreshRetainsModelAndResetsDetail() throws {
        let catalog = try fixture(); var models = TimelineRenderer.models(catalog: catalog, companies: companies)
        var state = TimelineState(); state.reconcile(models: models)
        state.handle(.next, models: models, scrollLimit: 0); state.handle(.down, models: models, scrollLimit: 0)
        let id = state.selectedID; state.detailOffset = 50
        state.reconcile(models: models, catalogUpdate: true)
        XCTAssertEqual(state.selectedID, id); XCTAssertEqual(state.detailOffset, 0)
        models.removeAll { $0.id == id }; state.reconcile(models: models, catalogUpdate: true)
        XCTAssertNotEqual(state.selectedID, id); XCTAssertTrue(state.isCompanyPage)
    }
    func testEveryFrameFitsAndTooSmallIsOneLine() throws {
        let catalog = try fixture()
        for columns in [70, 79, 80, 102, 200] { for rows in [18, 20, 21, 31] {
            let rendered = frame(catalog, TimelineState(), rows: rows, columns: columns, color: true).text
            let lines = rendered.components(separatedBy: "\n")
            XCTAssertLessThanOrEqual(lines.count, rows - 1)
            for line in lines { XCTAssertLessThanOrEqual(TerminalText.width(line), min(columns - 2, 104)) }
            if columns < 80 || rows < 21 { XCTAssertEqual(lines.count, 1) }
            else { XCTAssertEqual(lines.count, rows - 1) }
        } }
    }
}
