import Foundation

public struct ReleaseCadence {
    public let gaps: [Int]
    public let daysSinceLatest: Int?

    public init(models: [CatalogModel], companyID: String, now: Date) {
        let today = ReleaseDates.calendar.startOfDay(for: now)
        let dates = Set(models.filter { $0.id.hasPrefix(companyID + "/") }
            .compactMap(\.exactDate).filter { $0 <= today }).sorted(by: >).prefix(5)
        gaps = zip(dates, dates.dropFirst()).map { ReleaseDates.days($1, $0) }.reversed()
        daysSinceLatest = dates.first.map { ReleaseDates.days($0, now) }
    }

    public var label: String {
        guard !gaps.isEmpty, let daysSinceLatest else { return "one release on record" }
        let ordered = gaps.sorted()
        let middle = ordered.count / 2
        let median = ordered.count % 2 == 0 ? Int(ceil(Double(ordered[middle - 1] + ordered[middle]) / 2)) : ordered[middle]
        return "gaps " + gaps.map(String.init).joined(separator: "→") + "d"
            + (gaps.count > 1 ? " · median \(median)d" : "") + " · last \(daysSinceLatest)d ago"
    }
}
