import XCTest
@testable import CookedCore

final class ResponsivenessTests: XCTestCase {
    func testGlobalShortcutsYieldToSearchAndKeepViewCommandsLocal() {
        var decoder = TerminalKeyDecoder()
        let shortcuts = decoder.decode(Array("aAdDsSqQ\t".utf8))
        XCTAssertEqual(shortcuts.compactMap { $0.globalCommand(searching: false) },
                       [.tabLeft, .tabLeft, .tabRight, .tabRight, .share, .shareCompany, .quit, .quit, .tabRight])
        XCTAssertEqual(shortcuts.last, .tab)
        let local: [TerminalKey] = [.text("c"), .text("b"), .text("/"), .up, .down, .previous, .next,
                                    .enter, .escape, .toggle, .backspace, .clear]
        XCTAssertTrue(local.allSatisfy { $0.globalCommand(searching: false) == nil })
        XCTAssertTrue((shortcuts + local + [.share, .quit, .tabLeft, .tabRight]).allSatisfy {
            $0.globalCommand(searching: true) == nil
        })
    }

    func testArrowSequencesPreserveOrderAcrossReads() {
        var decoder = TerminalKeyDecoder()
        XCTAssertEqual(decoder.decode(Array("da ".utf8)).map(\.command), [.tabRight, .tabLeft, .toggle])
        XCTAssertEqual(decoder.decode([27, 91]), [])
        XCTAssertEqual(decoder.decode([65, 27, 91, 66, 27, 79, 67, 27, 79, 68]), [.up, .down, .next, .previous])
        XCTAssertEqual(decoder.decode(Array("hjkl".utf8)), [.text("h"), .text("j"), .text("k"), .text("l")])
        XCTAssertEqual(decoder.decode([27, 91, 49, 59, 53, 65]), [.up])
        XCTAssertEqual(decoder.decode([27, 91, 51, 126, 113]).map(\.command), [.escape, .quit])
    }
    func testIncompleteEscapesDoNotSwallowTheNextCommand() {
        var decoder = TerminalKeyDecoder()
        XCTAssertEqual(decoder.decode([27, 91]), [])
        XCTAssertEqual(decoder.flushEscape(), [.escape])
        XCTAssertEqual(decoder.decode(Array("q".utf8)).map(\.command), [.quit])
        XCTAssertEqual(decoder.decode([27, 91, 27, 91, 66]), [.escape, .down])
        XCTAssertEqual(decoder.flushEscape(), [])
    }
    func testUnicodeSurvivesSplitReadsButNotAnInterruptedSequence() {
        var decoder = TerminalKeyDecoder()
        let bytes = Array("界".utf8)
        XCTAssertEqual(decoder.decode([bytes[0]]), [])
        XCTAssertEqual(decoder.decode(Array(bytes.dropFirst())), [.text("界")])
        XCTAssertEqual(decoder.decode([bytes[0], 27]), [])
        XCTAssertEqual(decoder.flushEscape(), [.escape])
        XCTAssertEqual(decoder.decode(Array(bytes.dropFirst()) + Array("s".utf8)), [.text("s")])
    }
    func testTimelineNavigationTiming() throws {
        let companies = ModelCompany.configured()
        let records = (0..<11).flatMap { company in
            (0..<40).flatMap { model in
                ["a", "b"].map { suffix in
                    "\"\(companies[company].id)/m\(model)-\(suffix)\":{\"id\":\"m\(model)-\(suffix)\",\"name\":\"Model \(model) \(suffix)\",\"release_date\":\"2026-\(String(format: "%02d", 1 + model % 9))-\(String(format: "%02d", 1 + model % 28))\"}"
                }
            }
        }.joined(separator: ",")
        let now = ReleaseDates.parse("2026-09-15")!
        let catalog = try ModelCatalog.decode(metadata: Data(("{" + records + "}").utf8), prices: nil, companies: companies, now: now)
        let models = TimelineRenderer.models(catalog: catalog, companies: companies)
        let releases = TimelineRelease.grouped(models: models)
        XCTAssertEqual(releases.count, 440)
        XCTAssertTrue(releases.allSatisfy { $0.models.count == 2 })
        var state = TimelineState()
        state.reconcile(models: models)
        let start = Date()
        for _ in 0..<30 {
            let frame = TimelineRenderer.frame(catalog: catalog, companies: companies, state: state,
                                                now: now, rows: 45, columns: 150, loading: false, color: true)
            XCTAssertTrue(frame.text.contains("→ company"))
            XCTAssertTrue(frame.text.contains(" │ "))
            state.handle(.down, models: models, scrollLimit: frame.scrollLimit)
        }
        XCTAssertEqual(state.cursor, 30)
        XCTAssertEqual(state.releaseID, releases[30].id)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed / 30, 0.1)
        print("TIMELINE average milliseconds: \(elapsed / 30 * 1000)")
    }
}
