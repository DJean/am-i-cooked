import Foundation
import Testing
@testable import CookedCore

private struct FixtureProvider: UsageProvider {
    let snapshot: ProviderSnapshot?
    func fetch(now: Date) async -> ProviderSnapshot? { snapshot }
}

@Test func providersHideMissingAndKeepDeclaredOrderWithinEachState() async {
    let snapshots = await fetchProviders([
        FixtureProvider(snapshot: ProviderSnapshot(title: "Offline A", notes: ["Retrying"])),
        FixtureProvider(snapshot: ProviderSnapshot(title: "Codex", metrics: [Metric("Quota", "10%", progress: 0.1)])),
        FixtureProvider(snapshot: nil),
        FixtureProvider(snapshot: ProviderSnapshot(title: "Other", metrics: [Metric("Month", "$1", period: .month)])),
        FixtureProvider(snapshot: ProviderSnapshot(title: "Offline B", notes: ["Retrying"]))
    ], now: Date())
    #expect(snapshots.map(\.title) == ["Codex", "Other", "Offline A", "Offline B"])
}
