import Foundation
import Testing
@testable import CookedCore

private let refreshCompanies = [ModelCompany(id: "anthropic", name: "Anthropic", priceSources: ["anthropic"])]
private let refreshMetadata = Data(#"{"anthropic/claude-a":{"id":"anthropic/claude-a","name":"Claude A","release_date":"2026-09-01"}}"#.utf8)
private let refreshAPI = Data(#"{"anthropic":{"models":{"claude-a":{"id":"claude-a","name":"Claude A","release_date":"2026-09-01","cost":{"input":2}}}},"amazon-bedrock":{"models":{"anthropic.claude-a-v1:0":{"id":"anthropic.claude-a-v1:0","name":"Claude A","release_date":"2026-09-01"}}}}"#.utf8)

private actor CatalogGate {
    private(set) var opened = false
    private var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
    func wait() async throws {
        try Task.checkCancellation()
        guard !opened else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if opened { continuation.resume() }
                else { waiting[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) { waiting.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func open() {
        opened = true
        let continuations = waiting.values
        waiting.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private actor CatalogFrames {
    var values: [ModelCatalog] = []
    func append(_ value: ModelCatalog) { values.append(value) }
}

private func catalogResponse(_ request: URLRequest, _ data: Data) -> (Data, HTTPURLResponse) {
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(request.timeoutInterval == 20)
    #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}

@Test func catalogPublishesMetadataBeforeSlowPricesAndProviders() async throws {
    let prices = CatalogGate(), received = CatalogGate(), frames = CatalogFrames()
    let rescue = Task {
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        Issue.record("Metadata publication stalled while the API response was gated")
        await prices.open(); await received.open()
    }
    defer { rescue.cancel() }
    let fetch = Task {
        await ModelCatalogClient.fetch(companies: refreshCompanies, onMetadata: {
            await frames.append($0); await received.open()
        }, transport: { request in
            if request.url?.lastPathComponent == "api.json" { try await prices.wait(); return catalogResponse(request, refreshAPI) }
            return catalogResponse(request, refreshMetadata)
        })
    }
    defer { fetch.cancel() }
    try await received.wait()
    #expect(await prices.opened == false)
    let first = try #require(await frames.values.first)
    #expect(first.models.count == 1 && first.models[0].cost == nil)
    #expect(first.priceLoading && first.error == nil && first.priceError == nil)
    await prices.open()
    let final = await fetch.value
    #expect(!final.priceLoading && final.error == nil && final.priceError == nil)
    #expect(final.models[0].cost?.input == 2)
    #expect(final.models[0].deployments == [CatalogDeployment(host: "Bedrock", modelID: "anthropic.claude-a-v1:0")])
}

@Test(arguments: [false, true]) func catalogPriceFailureStillPublishesMetadata(invalidJSON: Bool) async throws {
    let frames = CatalogFrames()
    let final = await ModelCatalogClient.fetch(companies: refreshCompanies, onMetadata: { await frames.append($0) }, transport: { request in
        if request.url?.lastPathComponent == "api.json" {
            if invalidJSON { return catalogResponse(request, Data("invalid".utf8)) }
            throw URLError(.timedOut)
        }
        return catalogResponse(request, refreshMetadata)
    })
    #expect(await frames.values.count == 1)
    #expect(await frames.values.first?.priceLoading == true)
    #expect(final.models.count == 1 && final.error == nil && !final.priceLoading)
    #expect(final.priceError == (invalidJSON ? "Price data invalid" : "Prices unavailable"))
}

@Test func catalogMetadataFailureDoesNotWaitForAPI() async {
    let prices = CatalogGate(), started = CatalogGate(), frames = CatalogFrames()
    let rescue = Task {
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        Issue.record("Metadata failure waited for the gated API response")
        await prices.open(); await started.open()
    }
    defer { rescue.cancel() }
    let final = await ModelCatalogClient.fetch(companies: refreshCompanies, onMetadata: { await frames.append($0) }, transport: { request in
        if request.url?.lastPathComponent == "api.json" {
            await started.open(); try await prices.wait()
            return catalogResponse(request, refreshAPI)
        }
        try await started.wait()
        throw URLError(.notConnectedToInternet)
    })
    #expect(await prices.opened == false)
    #expect(final.error != nil && final.fetchedAt == nil && !final.priceLoading)
    #expect(await frames.values.isEmpty)
    await prices.open()
}

@Test func catalogMergingPreservesLastGoodFieldsWithoutResurrectingModels() throws {
    let oldMetadata = Data(#"{"anthropic/claude-a":{"id":"anthropic/claude-a","name":"Old name","release_date":"2026-09-01"},"anthropic/removed":{"id":"anthropic/removed","name":"Removed","release_date":"2026-08-01"}}"#.utf8)
    let old = try ModelCatalog.decode(metadata: oldMetadata, prices: refreshAPI, companies: refreshCompanies, now: Date(timeIntervalSince1970: 1))
    var partial = try ModelCatalog.decode(metadata: refreshMetadata, prices: nil, companies: refreshCompanies, now: Date(timeIntervalSince1970: 2))
    partial.priceLoading = true
    let first = partial.merging(previous: old)
    #expect(first.models.count == 1 && first.models[0].name == "Claude A")
    #expect(first.models[0].cost?.input == 2 && first.models[0].priceSource == "anthropic")
    #expect(first.models[0].deployments == old.models.first { $0.id == "anthropic/claude-a" }?.deployments)
    #expect(first.priceLoading && first.priceError == nil && first.fetchedAt == partial.fetchedAt)

    partial.priceLoading = false; partial.priceError = "Prices unavailable"
    let failedAPI = partial.merging(previous: first)
    #expect(failedAPI.models.count == 1 && failedAPI.models[0].cost?.input == 2)
    #expect(failedAPI.models[0].deployments == first.models[0].deployments && !failedAPI.priceLoading)

    var failedMetadata = ModelCatalog(); failedMetadata.error = "Unavailable"
    let failed = failedMetadata.merging(previous: old)
    #expect(failed.models.count == 2 && failed.fetchedAt == old.fetchedAt && failed.error == "Unavailable")
    let refreshed = try ModelCatalog.decode(metadata: refreshMetadata, prices: Data("{}".utf8), companies: refreshCompanies, now: Date())
        .merging(previous: old)
    #expect(refreshed.models[0].cost == nil && refreshed.models[0].deployments == [])
}
