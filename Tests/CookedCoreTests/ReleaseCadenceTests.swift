import XCTest
@testable import CookedCore

final class ReleaseCadenceTests: XCTestCase {
    private func model(_ id: String, _ date: String?) -> CatalogModel {
        CatalogModel(id: id, name: id, releaseDate: date, benchmarks: nil,
                     cost: nil, priceSource: nil)
    }

    func testSameDayModelsCountOnceAndOnlyPastExactCompanyDatesContribute() {
        let models = [model("openai/latest-b", "2026-09-10"), model("anthropic/other", "2026-09-14"),
                      model("openai/first", "2026-09-01"), model("openai/latest-a", "2026-09-10"),
                      model("openai/middle", "2026-09-04"), model("openai/future", "2026-09-16"),
                      model("openai/month", "2026-09"), model("openai/unknown", nil),
                      model("openai-compatible/other", "2026-09-15")]
        let cadence = ReleaseCadence(models: models, companyID: "openai",
                                     now: ReleaseDates.parse("2026-09-15")!.addingTimeInterval(86_399))
        XCTAssertEqual(cadence.gaps, [3, 6])
        XCTAssertEqual(cadence.daysSinceLatest, 5)
        XCTAssertEqual(cadence.label, "gaps 3→6d · median 5d · last 5d ago")
    }

    func testKeepsMostRecentFourIntervalsInChronologicalOrder() {
        let models = [22, 1, 11, 4, 16, 2, 7].map {
            model("openai/model-\($0)", String(format: "2026-09-%02d", $0))
        }
        let cadence = ReleaseCadence(models: models, companyID: "openai", now: ReleaseDates.parse("2026-09-25")!)
        XCTAssertEqual(cadence.gaps, [3, 4, 5, 6])
        XCTAssertEqual(cadence.daysSinceLatest, 3)
    }

    func testNoIntervalWithoutTwoDatesAndElapsedDaysChangeAtUTCMidnight() {
        let midnight = ReleaseDates.parse("2026-09-16")!
        let empty = ReleaseCadence(models: [], companyID: "openai", now: midnight)
        XCTAssertEqual(empty.gaps, []); XCTAssertNil(empty.daysSinceLatest); XCTAssertEqual(empty.label, "one release on record")
        let models = [model("openai/only", "2026-09-15")]
        let before = ReleaseCadence(models: models, companyID: "openai", now: midnight.addingTimeInterval(-1))
        let after = ReleaseCadence(models: models, companyID: "openai", now: midnight)
        XCTAssertEqual(before.gaps, []); XCTAssertEqual(after.gaps, [])
        XCTAssertEqual(before.daysSinceLatest, 0); XCTAssertEqual(after.daysSinceLatest, 1)
        XCTAssertEqual(before.label, "one release on record"); XCTAssertEqual(after.label, "one release on record")
    }
}
