import XCTest
import CoreGraphics
import ImageIO
@testable import CookedCore

final class ModelShareCardTests: XCTestCase {
    let now = ReleaseDates.parse("2026-09-24")!
    let companies = [ModelCompany(id: "openai", name: "OpenAI", priceSources: [])]
    func model(_ id: String, date: String = "2026-09-23", scores: Int = 1) -> CatalogModel {
        CatalogModel(id: id, name: id, releaseDate: date, benchmarks: (0..<scores).map { .init(name: "Benchmark \($0)", score: Double($0)) })
    }
    func catalog(_ models: [CatalogModel]) -> ModelCatalog { var c = ModelCatalog(); c.models = models; return c }
    func png(_ catalog: ModelCatalog, _ timeline: TimelineState = TimelineState(), comparison: ModelCompareState? = nil, lab: Bool = false) throws -> Data {
        try ModelShareCard.png(catalog: catalog, companies: companies, timeline: timeline, comparison: comparison, companyCard: lab, now: now)
    }
    func image(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    func testExplicitModelAndLabCardsIndependentOfScroll() throws {
        let c = catalog([model("openai/a"), model("openai/b")] + (1...8).map { model("openai/old-\($0)", date: String(format: "2026-09-%02d", 23 - $0)) })
        let models = TimelineRenderer.models(catalog: c, companies: companies)
        var state = TimelineState(); state.reconcile(models: models)
        let profile = try png(c, state), lab = try png(c, state, lab: true)
        XCTAssertNotEqual(profile, lab)
        state.handle(.next, models: models, scrollLimit: 0); state.detailOffset = 999
        XCTAssertEqual(try png(c, state), profile); XCTAssertEqual(try png(c, state, lab: true), lab)
        var changed = c; changed.models[changed.models.count - 1].name = "Outside six batches"
        XCTAssertEqual(try png(changed, state, lab: true), lab)
        XCTAssertEqual(try image(profile).width, 1200)
    }
    func testFullDataChangesCardsAndComparisonIgnoresViewport() throws {
        var c = catalog((0..<4).map { model("openai/model-\($0)", scores: 28) })
        c.models[0].description = "Complete model description"
        c.models[0].limits = .init(context: 1_000_000, output: 128000)
        var state = ModelCompareState(); state.searching = false; state.selectedIDs = c.models.map(\.id)
        let full = try png(c, comparison: state)
        state.selectedRow = 999; state.modelOffset = 3
        XCTAssertEqual(try png(c, comparison: state), full)
        XCTAssertEqual(try image(full).width, 2 * (88 + 210 + 160 * 4))
        c.models[3].benchmarks?[27].score = 999
        XCTAssertNotEqual(try png(c, comparison: state), full)
        let before = try png(c); c.models[0].description = "Changed description"
        XCTAssertNotEqual(try png(c), before)
    }
    func testIonPaletteAndLogoRasterization() throws {
        let m = model("openai/a")
        let ion = try ModelShareCard.profile(model: m, company: "OpenAI", now: now, note: "models.dev")
        let standard = try ModelShareCard.profile(model: m, company: "OpenAI", now: now.addingTimeInterval(86400 * 5), note: "models.dev")
        XCTAssertNotEqual(ion, standard)
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="M2 2H22V22H2Z" fill="currentColor"/></svg>"#.utf8)
        let mask = try XCTUnwrap(LabMarks.mask(svg))
        XCTAssertEqual(mask.width, 80); XCTAssertEqual(mask.height, 80)
        let marked = try ModelShareCard.profile(model: m, company: "OpenAI", now: now, note: "models.dev", mark: svg)
        XCTAssertNotEqual(marked, ion)
        XCTAssertNil(LabMarks.mask(Data("broken".utf8)))
    }
    func testWrapTiersAndExportCreatesDirectoryWithoutOverwrite() throws {
        let id = String(repeating: "region.model-界", count: 40) + "tail"
        XCTAssertEqual(ModelShareCard.wrap(id, columns: 62).joined(), id)
        let price = CatalogPrice(input: 0, output: nil, cacheRead: 0, cacheWrite: 0.25, tiers: [.init(input: 1, output: 2)])
        let rows = ModelShareCard.priceRows(price)
        XCTAssertEqual(rows.count, 9); XCTAssertEqual(rows[0].1, "$0"); XCTAssertEqual(rows[4].0, "over 200K ctx")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let c = catalog([model("openai/a")])
        let first = try ModelShareCard.save(catalog: c, companies: companies, timeline: TimelineState(), now: now, directory: directory)
        let second = try ModelShareCard.save(catalog: c, companies: companies, timeline: TimelineState(), now: now, directory: directory)
        XCTAssertTrue(second.lastPathComponent.hasSuffix("-2.png")); XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
        XCTAssertThrowsError(try png(ModelCatalog()))
        XCTAssertThrowsError(try png(catalog([model("openai/oversized", scores: 1000)]))) {
            XCTAssertEqual($0.localizedDescription, "Too many models to fit one card.")
        }
    }
}
