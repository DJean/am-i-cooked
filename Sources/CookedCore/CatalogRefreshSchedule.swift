import Foundation

public struct CatalogRefreshSchedule {
    public private(set) var loading = false
    public private(set) var nextFetch = Date.distantPast
    public init() {}

    public mutating func begin(now: Date) -> Bool {
        guard !loading, now >= nextFetch else { return false }
        loading = true
        return true
    }

    public mutating func finish(now: Date, succeeded: Bool) {
        loading = false
        nextFetch = now.addingTimeInterval(succeeded ? 30 * 60 : 60)
    }
}
