import XCTest
@testable import CookedCore

final class ModelCatalogTests: XCTestCase {
    let now = ReleaseDates.parse("2026-09-24")!
    func decode(_ metadata: String, _ prices: String? = nil) throws -> ModelCatalog {
        try ModelCatalog.decode(metadata: Data(metadata.utf8), prices: prices.map { Data($0.utf8) }, companies: ModelCompany.configured(), now: now)
    }
    func testMetadataUsesDictionaryIDAndSkipsPointersInvalidDatesAndScores() throws {
        let catalog = try decode(#"""
        {"openai/a":{"name":"A","release_date":"2026-09-01","description":"Reasoning","last_updated":"2026-09-02","knowledge":"2026-06","limit":{"context":1000000,"output":128000},"modalities":{"input":["text"],"output":["text"]},"benchmarks":[{"name":"Valid","score":42,"harness":"agent-v2"},{"name":"","score":10},{"name":"Bad","score":"oops"}]},
        "openai/a-latest":{"name":"Pointer","release_date":"2026-09-02"},"openai/bad":{"name":"Bad","release_date":"2026-02-30"},
        "openai/month":{"name":"Month","release_date":"2026-09"},"other/foreign":{"name":"Foreign","release_date":"2026-09-01"}}
        """#)
        XCTAssertEqual(catalog.models.count, 2)
        let a = try XCTUnwrap(catalog.models.first { $0.id == "openai/a" })
        XCTAssertEqual(a.description, "Reasoning"); XCTAssertEqual(a.limits?.context, 1_000_000)
        XCTAssertEqual(a.benchmarks?.count, 1); XCTAssertEqual(a.benchmarks?.first?.harness, "agent-v2")
        XCTAssertNil(catalog.models.first { $0.id == "openai/month" }?.exactDate)
        XCTAssertNil(ReleaseDates.parse("2026-02-30")); XCTAssertNil(ReleaseDates.parse("2026-13"))
    }
    func testExactOwnPricesSourceNamesAndDistinctTiers() throws {
        let catalog = try decode(#"{"openai/a":{"name":"A","release_date":"2026-09-01"},"openai/b":{"name":"B","release_date":"2026-09-01"}}"#,
            #"""
            {"openai":{"name":"OpenAI","models":{"a":{"cost":{"input":1,"output":2,"cache_read":0.1,"tiers":[{"input":1,"output":2,"tier":{"size":272000}},{"input":3,"output":4,"cache_write":5,"tier":{"size":300000}}],"context_over_200k":{"input":1,"output":2}}},"openai/b":{"cost":{"input":999}}}},
            "other":{"models":{"b":{"cost":{"input":888}}}}}
            """#)
        let a = try XCTUnwrap(catalog.models.first { $0.id == "openai/a" })
        XCTAssertEqual(a.priceSource, "OpenAI"); XCTAssertEqual(a.cost?.input, 1)
        XCTAssertEqual(a.cost?.distinctTiers.count, 1); XCTAssertEqual(a.cost?.distinctTiers.first?.label, "over 300K ctx")
        XCTAssertEqual(a.cost?.distinctTiers.first?.cacheWrite, 5)
        XCTAssertNil(catalog.models.first { $0.id == "openai/b" }?.cost)
    }
    func testMalformedBenchmarkDoesNotDiscardValidModelOrOtherScores() throws {
        let catalog = try decode(#"""
        {"openai/bad":false,"openai/a":{"name":"A","release_date":"2026-09-01","cost":"ignored metadata field","deployments":false,"benchmarks":[
            {"name":"Valid","score":42}, {"name":"Boolean","score":true},
            {"name":"Bad condition","score":10,"harness":5}, null
        ]}}
        """#)
        XCTAssertEqual(catalog.models.map(\.id), ["openai/a"])
        XCTAssertEqual(catalog.models.first?.benchmarks?.map(\.name), ["Valid"])
    }
    func testTierDeduplicationUsesExactThresholdAndNormalizesLegacyDefault() throws {
        let catalog = try decode(#"{"openai/a":{"name":"A","release_date":"2026-09-01"}}"#, #"""
        {"openai":{"models":{"a":{"cost":{"input":1,"tiers":[
            {"input":2,"tier":{"size":200000}}, {"input":2,"tier":{"size":200001}}
        ],"context_over_200k":{"input":2}}}}}}
        """#)
        let tiers = try XCTUnwrap(catalog.models.first?.cost?.distinctTiers)
        XCTAssertEqual(tiers.count, 2)
        XCTAssertEqual(tiers.map { $0.threshold?.size }, [200_000, 200_001])
    }
    func testDeploymentAliasesSuffixesMissingIDAndAmbiguity() throws {
        let catalog = try decode(#"""
        {"anthropic/opus":{"name":"Opus","release_date":"2026-09-01"},"moonshotai/kimi-k2.6":{"name":"Kimi","release_date":"2026-09-01"},
        "openai/same":{"name":"Ambiguous","release_date":"2026-09-01"},"anthropic/same":{"name":"Ambiguous","release_date":"2026-09-01"}}
        """#, #"""
        {"amazon-bedrock":{"models":{"eu.extra.anthropic.opus-v1:0":{"name":"Regional Opus"},"alias":{"id":"us.anthropic.opus-v2","name":"Opus"},"bad":{"name":"Ambiguous"}}},
         "fireworks-ai":{"models":{"any/path/kimi-k2p6":{"name":"Kimi variant"},"ambiguous/path/same":{"name":"Ambiguous"}}},
         "unlisted":{"models":{"opus":{"name":"Opus"}}}}
        """#)
        XCTAssertEqual(catalog.models.first { $0.id == "anthropic/opus" }?.deployments?.map(\.modelID), ["eu.extra.anthropic.opus-v1:0", "us.anthropic.opus-v2"])
        XCTAssertEqual(catalog.models.first { $0.id == "moonshotai/kimi-k2.6" }?.deployments?.first?.modelID, "any/path/kimi-k2p6")
        XCTAssertTrue(catalog.models.filter { $0.name == "Ambiguous" }.allSatisfy { $0.deployments?.isEmpty == true })
    }
    func testLiveDownloadedSchemaWhenProvided() throws {
        guard let directory = ProcessInfo.processInfo.environment["COOKED_CATALOG_FIXTURES"] else { throw XCTSkip("Optional public schema check") }
        let catalog = try ModelCatalog.decode(metadata: Data(contentsOf: URL(fileURLWithPath: directory + "/models-dev-models.json")),
            prices: Data(contentsOf: URL(fileURLWithPath: directory + "/models-dev-api.json")), companies: ModelCompany.configured(), now: now)
        XCTAssertGreaterThan(catalog.models.count, 100)
        XCTAssertTrue(catalog.models.contains { $0.cost != nil && $0.description != nil && $0.limits?.context != nil })
        XCTAssertTrue(catalog.models.contains { $0.deployments?.isEmpty == false })
        XCTAssertTrue(catalog.models.allSatisfy { !$0.id.hasSuffix("-latest") && $0.date != nil })
    }
}
