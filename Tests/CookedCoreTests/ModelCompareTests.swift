import XCTest
@testable import CookedCore

final class ModelCompareTests: XCTestCase {
    func model(_ id: String, _ score: Double = 100) -> CatalogModel {
        CatalogModel(id: id, name: id, releaseDate: "2026-09-01", benchmarks: [ModelBenchmark(name: "Eval", score: score, version: "1")])
    }
    func catalog() -> ModelCatalog {
        var catalog = ModelCatalog(); catalog.models = [model("a"), model("b", 110), model("c", 120)]; return catalog
    }
    func state(_ catalog: ModelCatalog) -> ModelCompareState {
        var state = ModelCompareState(); state.searching = false; state.selectedIDs = catalog.models.map(\.id); return state
    }
    func testSearchPickingClearBackspaceAndShortcuts() {
        let catalog = catalog(); var state = ModelCompareState()
        func key(_ key: TerminalKey) { _ = state.handle(key, catalog: catalog, scrollLimit: 100, modelLimit: 10) }
        key(.text("b")); key(.enter)
        XCTAssertEqual(state.selectedIDs, ["b"]); XCTAssertEqual(state.query, "")
        key(.tab); XCTAssertTrue(state.searching)
        key(.text("a")); key(.enter); key(.tab)
        XCTAssertFalse(state.searching); XCTAssertEqual(state.effectiveBaseline(), "b")
        key(.text("B")); XCTAssertEqual(state.effectiveBaseline(), "a")
        key(.text("C")); XCTAssertTrue(state.searching)
        key(.backspace); XCTAssertEqual(state.selectedIDs, ["b"])
        for text in ["q", "s", "Q", "S", "j", "k"] { key(.text(text)) }
        XCTAssertEqual(state.query, "qsQSjk"); key(.clear); XCTAssertEqual(state.query, "")
        XCTAssertTrue(state.handle(.escape, catalog: catalog, scrollLimit: 0, modelLimit: 0))
    }
    func testRefreshDropsMissingPicksAndLeavesInvalidComparison() {
        var catalog = catalog(), state = state(catalog)
        state.baselineID = "b"; catalog.models.removeAll { $0.id != "a" }; state.reconcile(catalog: catalog)
        XCTAssertEqual(state.selectedIDs, ["a"]); XCTAssertTrue(state.searching); XCTAssertNil(state.baselineID)
    }
    func testAllNumericRowsAndDeltasIncludePriceAndLimits() {
        var catalog = catalog()
        catalog.models[0].limits = .init(context: 1_000_000, output: 128000)
        catalog.models[1].limits = .init(context: 1_050_000, output: 64000)
        catalog.models[0].cost = .init(input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5)
        catalog.models[1].cost = .init(input: 0.2, output: 1.2, cacheRead: 0.02, cacheWrite: 0.25)
        let comparison = ModelComparison(catalog: catalog, state: state(catalog))
        XCTAssertEqual(comparison.rows.map(\.name), ["Context", "Max output", "Input $/1M", "Output $/1M", "Cache read $/1M", "Cache write $/1M", "Eval"])
        XCTAssertEqual(comparison.rows[0].values, ["1M", "1.05M", "—"])
        XCTAssertEqual(comparison.rows[0].changes[1], "+5%")
        XCTAssertEqual(comparison.rows[2].changes[1], "-95%")
        XCTAssertEqual(comparison.rows.last?.changes, ["0%", "+10%", "+20%"])
    }
    func testEveryBenchmarkConditionIncludingHarnessSeparatesScores() {
        for field in 0..<5 {
            var catalog = catalog()
            var score = catalog.models[1].benchmarks![0]
            switch field { case 0: score.version = "2"; case 1: score.variant = "tools"; case 2: score.metric = "loss"; case 3: score.dataset = "other"; default: score.harness = "different-agent" }
            catalog.models[1].benchmarks = [score]
            let rows = ModelComparison(catalog: catalog, state: state(catalog)).rows
            XCTAssertEqual(rows.count, 2)
            XCTAssertTrue(rows.allSatisfy { !$0.condition.isEmpty && $0.changes[1] == "—" })
        }
    }
    func testMissingZeroAndConflictingValuesNeverHaveDelta() {
        var catalog = catalog()
        catalog.models[0].benchmarks = [.init(name: "Zero", score: 0), .init(name: "Conflict", score: 10), .init(name: "Conflict", score: 20), .init(name: "Duplicate", score: 100), .init(name: "Duplicate", score: 100)]
        catalog.models[1].benchmarks = [.init(name: "Zero", score: 10), .init(name: "Conflict", score: 30), .init(name: "Duplicate", score: 110)]
        let rows = ModelComparison(catalog: catalog, state: state(catalog)).rows
        XCTAssertEqual(rows.first { $0.name == "Conflict" }?.values[0], "10 / 20")
        XCTAssertEqual(rows.first { $0.name == "Conflict" }?.changes[1], "—")
        XCTAssertEqual(rows.first { $0.name == "Zero" }?.changes[1], "—")
        XCTAssertEqual(rows.first { $0.name == "Duplicate" }?.changes[1], "+10%")
        XCTAssertEqual(ModelFigure.delta(-5, -10), "+50%")
        XCTAssertEqual(ModelFigure.delta(100, 100), "0%")
        XCTAssertEqual(ModelFigure.delta(1e306, 1), "+1.0e+308%")
    }
    func testFramesFitSearchPicksAndOffscreenReference() {
        var catalog = catalog(); catalog.models += (0..<8).map { model("Extra \($0)") }
        for searching in [false, true] { for width in [79, 80, 106, 200] {
            var state = state(catalog); state.searching = searching; state.modelOffset = 4
            let frame = ModelCompareRenderer.frame(catalog: catalog, state: state, rows: 25, columns: width, color: true, now: Date(timeIntervalSince1970: 1_800_000_000))
            let lines = frame.text.components(separatedBy: "\n")
            XCTAssertEqual(lines.count, width < 80 ? 1 : 24)
            for line in lines { XCTAssertLessThanOrEqual(TerminalText.width(line), min(width - 2, 104)) }
            if width >= 80 && !searching { XCTAssertTrue(frame.text.contains("ref: a")); XCTAssertGreaterThan(frame.modelLimit, 0) }
            if width >= 80 && searching { XCTAssertTrue(frame.text.contains("Compare")); XCTAssertTrue(frame.text.contains("+")) }
        } }
    }
    func testFigureFormattingAndDuplicateNames() {
        XCTAssertEqual(ModelFigure.tokens(131072), "128K"); XCTAssertEqual(ModelFigure.tokens(128000), "128K")
        XCTAssertEqual(ModelFigure.tokens(0), "—"); XCTAssertEqual(ModelFigure.tokens(12345), "12.3K")
        XCTAssertEqual(ModelFigure.rate(0.00001), "$1.0e-05"); XCTAssertEqual(ModelFigure.rate(0.123456), "$0.1235")
        XCTAssertEqual(ModelFigure.score(10.123), "10.1")
        var catalog = catalog(); catalog.models[1].name = "a"
        XCTAssertEqual(ModelComparison(catalog: catalog, state: state(catalog)).names, ["a (a)", "a (b)", "c"])
    }
    func testLargeTokenLimitsDoNotRoundTripThroughDouble() {
        var catalog = catalog()
        catalog.models[0].limits = .init(context: Int.max, output: Int.max - 1)
        let rows = ModelComparison(catalog: catalog, state: state(catalog)).rows
        XCTAssertEqual(rows[0].values[0], ModelFigure.tokens(Int.max))
        XCTAssertEqual(rows[1].values[0], ModelFigure.tokens(Int.max - 1))
    }
    func testExternalBenchmarkTextCannotInjectTerminalControls() {
        var catalog = catalog()
        catalog.models[0].benchmarks = [.init(name: "Eval\u{1B}[2J\n", score: 1, variant: "\u{1B}]0;title\u{7}")]
        catalog.models[1].benchmarks = [.init(name: "Eval\u{1B}[2J\n", score: 2, variant: "safe")]
        let rendered = ModelCompareRenderer.frame(catalog: catalog, state: state(catalog), rows: 25, columns: 106,
            color: false, now: Date(timeIntervalSince1970: 1_800_000_000)).text
        XCTAssertFalse(rendered.contains("\u{1B}"))
        XCTAssertFalse(rendered.contains("\u{7}"))
        XCTAssertEqual(rendered.components(separatedBy: "\n").count, 24)
    }
    func testRemovingReferenceWithBackspaceResetsReference() {
        let catalog = catalog(); var state = state(catalog)
        state.searching = true; state.baselineID = "c"
        _ = state.handle(.backspace, catalog: catalog, scrollLimit: 0, modelLimit: 0)
        XCTAssertNil(state.baselineID)
        XCTAssertEqual(state.effectiveBaseline(), "a")
    }
}
