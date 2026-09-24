import Foundation

public struct TimelineRelease {
    public let companyID: String
    public let date: Date?
    public let models: [CatalogModel]
    public var id: String { date == nil ? models[0].id : companyID + "/" + models[0].releaseDate! }

    public static func grouped(models: [CatalogModel]) -> [Self] {
        var releases: [Self] = [], indices: [String: Int] = [:]
        for model in models {
            let release = Self(companyID: String(model.id.prefix { $0 != "/" }), date: model.exactDate, models: [model])
            if release.date != nil, let index = indices[release.id] {
                let previous = releases[index]
                releases[index] = Self(companyID: previous.companyID, date: previous.date, models: previous.models + [model])
            } else {
                if release.date != nil { indices[release.id] = releases.count }
                releases.append(release)
            }
        }
        return releases
    }
}

public struct TimelineState: Sendable {
    public var selectedID: String?
    public var cursor = 0
    public var detailOffset = 0
    public var releaseID: String?
    public var companyID: String?
    public var isCompanyPage: Bool { companyID != nil }
    public init() {}

    public mutating func reconcile(models: [CatalogModel], catalogUpdate: Bool = false) {
        let releases = TimelineRelease.grouped(models: models).filter { $0.date != nil }
        if catalogUpdate { detailOffset = 0 }
        if let companyID {
            let candidates = models.filter { $0.id.hasPrefix(companyID + "/") }
            if !candidates.isEmpty {
                if !candidates.contains(where: { $0.id == selectedID }) { selectedID = candidates[min(max(0, cursor), candidates.count - 1)].id }
                cursor = candidates.firstIndex { $0.id == selectedID } ?? 0
                return
            }
            self.companyID = nil
        }
        guard !releases.isEmpty else { selectedID = nil; cursor = 0; releaseID = nil; return }
        let retained = selectedID.flatMap { id in releases.firstIndex { $0.models.contains { $0.id == id } } }
            ?? releaseID.flatMap { id in releases.firstIndex { $0.id == id } }
        cursor = retained ?? min(max(0, cursor), releases.count - 1)
        releaseID = releases[cursor].id
        selectedID = releases[cursor].models[0].id
    }

    public mutating func handle(_ key: TerminalKey, models: [CatalogModel], scrollLimit: Int, paneRows: Int = 15) {
        reconcile(models: models)
        let releases = TimelineRelease.grouped(models: models).filter { $0.date != nil }
        switch key.command {
        case .next:
            guard !isCompanyPage, !releases.isEmpty else { return }
            let companyID = releases[cursor].companyID
            self.companyID = companyID
            let candidates = models.filter { $0.id.hasPrefix(companyID + "/") }
            cursor = candidates.firstIndex { $0.id == selectedID } ?? 0
            detailOffset = 0
        case .previous, .escape:
            guard isCompanyPage else { return }
            companyID = nil; selectedID = nil
            cursor = releases.firstIndex { $0.id == releaseID } ?? 0
            reconcile(models: models); detailOffset = 0
        case .toggle:
            let bottom = max(0, scrollLimit)
            detailOffset = detailOffset >= bottom ? 0 : min(detailOffset + max(1, paneRows - 2), bottom)
        case .up, .down:
            let step = key.command == .up ? -1 : 1
            if let companyID {
                let candidates = models.filter { $0.id.hasPrefix(companyID + "/") }
                guard !candidates.isEmpty else { return }
                cursor = min(candidates.count - 1, max(0, cursor + step)); selectedID = candidates[cursor].id
            } else {
                guard !releases.isEmpty else { return }
                cursor = min(releases.count - 1, max(0, cursor + step))
                releaseID = releases[cursor].id; selectedID = releases[cursor].models[0].id
            }
            detailOffset = 0
        default: break
        }
    }
}
