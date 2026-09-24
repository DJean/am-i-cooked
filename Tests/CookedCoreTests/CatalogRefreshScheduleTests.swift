import Testing
import Foundation
@testable import CookedCore

@Test func catalogLoadsAtStartupThenWaitsThirtyMinutesAcrossTabChanges() {
    var schedule = CatalogRefreshSchedule()
    func begin(_ date: Date) -> Bool { schedule.begin(now: date) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(begin(now))
    #expect(!begin(now.addingTimeInterval(60)))
    let completed = now.addingTimeInterval(2)
    schedule.finish(now: completed, succeeded: true)
    for elapsed in [0.0, 1, 60, 1799] {
        #expect(!begin(completed.addingTimeInterval(elapsed)))
    }
    #expect(begin(completed.addingTimeInterval(1800)))
}

@Test func failedCatalogFetchRetriesAfterOneMinuteWithoutOverlappingRequests() {
    var schedule = CatalogRefreshSchedule()
    func begin(_ date: Date) -> Bool { schedule.begin(now: date) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(begin(now))
    schedule.finish(now: now, succeeded: false)
    #expect(!begin(now.addingTimeInterval(59)))
    #expect(begin(now.addingTimeInterval(60)))
    #expect(!begin(now.addingTimeInterval(120)))
    schedule.finish(now: now.addingTimeInterval(121), succeeded: true)
    #expect(schedule.nextFetch == now.addingTimeInterval(1921))
}
