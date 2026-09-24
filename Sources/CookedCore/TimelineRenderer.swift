import Foundation

public struct TimelineFrame {
    public var text: String
    public var scrollLimit: Int
}

extension CatalogModel {
    var facts: [String] {
        var facts: [String] = []
        let limits = [(limits?.context, "context"), (limits?.output, "output")].compactMap { value, label in
            value.flatMap { $0 > 0 ? ModelFigure.tokens($0) + " " + label : nil }
        }
        if !limits.isEmpty { facts.append(limits.joined(separator: " · ")) }
        if let inputs = modalities?.input, let outputs = modalities?.output, !inputs.isEmpty, !outputs.isEmpty {
            facts.append(inputs.joined(separator: " · ") + " → " + outputs.joined(separator: " · "))
        }
        var dates: [String] = []
        if let knowledge, !knowledge.isEmpty { dates.append("knows to " + knowledge) }
        if let lastUpdated, lastUpdated != releaseDate, !lastUpdated.isEmpty { dates.append("refreshed " + lastUpdated) }
        if !dates.isEmpty { facts.append(dates.joined(separator: " · ")) }
        return facts
    }
    public func isNewRelease(now: Date) -> Bool { exactDate.map { (0...2).contains(ReleaseDates.days($0, now)) } ?? false }
}

extension TimelineRelease {
    var summary: String {
        let names = models.map { TerminalText.clean($0.name) }
        guard let first = names.first else { return "" }
        var common = Array(first.split(separator: " ").dropLast())
        while !common.isEmpty && !names.allSatisfy({ $0.hasPrefix(common.joined(separator: " ") + " ") }) { common.removeLast() }
        let prefix = common.isEmpty ? "" : common.joined(separator: " ") + " "
        return prefix + names.map { String($0.dropFirst(prefix.count)) }.joined(separator: " / ")
    }
}

public enum TimelineRenderer {
    public static func models(catalog: ModelCatalog, companies: [ModelCompany]) -> [CatalogModel] {
        let allowed = Set(companies.map(\.id))
        return catalog.models.filter {
            allowed.contains(String($0.id.prefix { $0 != "/" })) && !$0.id.hasSuffix("-latest") && $0.date != nil
        }.sorted { $0.date == $1.date ? $0.id < $1.id : ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
    static func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let days = ReleaseDates.days(date, now), span = "\(abs(days)) \(abs(days) == 1 ? "day" : "days")"
        return days == 0 ? "today" : days > 0 ? span + " ago" : "in " + span
    }
    static func details(_ model: CatalogModel, width: Int, ui: TerminalChrome) -> [String] {
        func pair(_ label: String, _ value: String, indent: String = "") -> String {
            let value = TerminalText.clip(value, to: max(1, width / 2))
            return ui.muted(indent + TerminalText.pad(TerminalText.clip(label, to: max(1, width - TerminalText.width(value) - indent.count - 1)), to: max(1, width - TerminalText.width(value) - indent.count))) + value
        }
        var lines: [String] = []
        if let summary = model.description, !summary.isEmpty { lines += TerminalText.wrap(summary, to: width).map(ui.muted) + [""] }
        for fact in model.facts { lines += TerminalText.wrap(fact, to: width).map(ui.muted) }
        if !model.facts.isEmpty { lines.append("") }
        lines += [ui.track("PRICE  USD / 1M"), pair("Source", TerminalText.clean(model.priceSource ?? "—"))]
        for (name, value) in [("Input", model.cost?.input), ("Output", model.cost?.output), ("Cache read", model.cost?.cacheRead), ("Cache write", model.cost?.cacheWrite)] {
            lines.append(pair(name, ModelFigure.rate(value)))
        }
        for tier in model.cost?.distinctTiers ?? [] {
            lines.append(ui.muted(tier.label))
            for (name, value) in [("Input", tier.input), ("Output", tier.output), ("Cache read", tier.cacheRead), ("Cache write", tier.cacheWrite)] {
                lines.append(pair(name, ModelFigure.rate(value), indent: "  "))
            }
        }
        lines += ["", ui.track("PROVIDERS")]
        let deployments = model.deployments ?? []
        if deployments.isEmpty { lines.append("—") }
        var host = ""
        for deployment in deployments {
            if host != deployment.host { host = deployment.host; lines.append(ui.muted(TerminalText.clean(host))) }
            lines += TerminalText.wrap(deployment.modelID, to: max(1, width - 2)).map { "  " + $0 }
        }
        lines += ["", ui.track("BENCHMARKS")]
        if model.benchmarks?.isEmpty != false { lines.append("—") }
        for score in model.benchmarks ?? [] {
            let number = ModelFigure.score(score.score)
            let labels = TerminalText.wrap(score.name, to: max(1, width - TerminalText.width(number) - 2))
            for (i, label) in labels.enumerated() { lines.append(pair(label, i == 0 ? number : "")) }
        }
        return lines
    }

    public static func frame(catalog: ModelCatalog, companies: [ModelCompany], state: TimelineState,
                             now: Date, rows: Int, columns: Int, loading: Bool, color: Bool, notice: String? = nil) -> TimelineFrame {
        let width = min(104, max(1, columns - 2)), budget = max(1, rows - 1)
        guard columns >= 80, rows >= 21 else {
            return TimelineFrame(text: TerminalChrome.tooSmall(rows: rows, columns: columns, minimumRows: 21), scrollLimit: 0)
        }
        let ui = TerminalChrome(width: width, color: color), paneRows = budget - 5
        let models = models(catalog: catalog, companies: companies)
        let releases = TimelineRelease.grouped(models: models).filter { $0.date != nil }
        let status = catalog.priceError != nil ? "prices incomplete" : loading || catalog.priceLoading ? "models.dev · loading" : nil
        var lines = ui.header(now: now, models: true, state: status)
        var selection = state; selection.reconcile(models: models)
        guard let model = models.first(where: { $0.id == selection.selectedID }) else {
            lines += [ui.muted(loading ? "Loading models.dev..." : catalog.error ?? "No dated model releases available.")]
            lines += Array(repeating: "", count: max(0, budget - lines.count - 2))
            lines += [ui.rule, ui.footer("tab usage · q quit", notice: notice)]
            return TimelineFrame(text: ui.finish(lines), scrollLimit: 0)
        }
        let leftWidth = min(max(width - 33, 34), 60), rightWidth = width - leftWidth - 3
        func cell(_ text: String, _ n: Int) -> String { TerminalText.pad(TerminalText.clip(text, to: n), to: n) }
        func company(_ id: String) -> String { TerminalText.clean(companies.first { $0.id == id }?.name ?? id) }
        let companyID = String(model.id.prefix { $0 != "/" })
        var left: [String] = []
        if selection.isCompanyPage {
            left = [ui.style(company(companyID), "1"), ui.muted(ReleaseCadence(models: models, companyID: companyID, now: now).label), ""]
            let candidates = models.filter { $0.id.hasPrefix(companyID + "/") }
            let capacity = max(1, paneRows - 3), offset = max(0, selection.cursor - capacity + 1)
            var previousDate: String?
            for candidate in candidates.dropFirst(offset).prefix(capacity) {
                let selected = candidate.id == selection.selectedID, date = candidate.releaseDate ?? "—"
                let shownDate = date == previousDate ? "" : date; previousDate = date
                let badge = candidate.isNewRelease(now: now) ? ui.style(" NEW", "38;5;167") : ""
                let label = cell(shownDate, 12) + candidate.name
                left.append((selected ? ui.style("▸ ", "38;5;73") : "  ")
                    + ui.style(TerminalText.clip(TerminalText.clean(label), to: leftWidth - 2 - TerminalText.width(badge)), selected ? "1" : "0") + badge)
            }
        } else {
            left = [ui.muted("  " + cell("Date", 12) + cell("Company", 13) + "Models")]
            let capacity = max(1, (paneRows - 1) / 4), offset = max(0, selection.cursor - capacity + 1)
            let nameWidth = leftWidth - 27
            for (i, release) in releases.enumerated().dropFirst(offset).prefix(capacity) {
                let selected = i == selection.cursor, recent = release.models[0].isNewRelease(now: now)
                let badge = recent ? ui.style(" NEW", "38;5;167") : ""
                left.append((selected ? ui.style("▸ ", "38;5;73") : "  ")
                    + ui.style(cell(release.models[0].releaseDate ?? "—", 12), selected ? "1" : "0")
                    + ui.style(cell(company(release.companyID), 13), selected ? "1" : "38;5;245")
                    + ui.style(TerminalText.clip(release.summary, to: nameWidth - (recent ? 4 : 0)), selected ? "1" : "0") + badge)
                let previous = Array(releases.filter { $0.companyID == release.companyID && ($0.date ?? .distantFuture) < (release.date ?? .distantPast) }.prefix(2))
                for n in 0..<2 {
                    let suffix = n < previous.count ? " · " + age(previous[n].date, now: now) : ""
                    let history = n < previous.count ? TerminalText.clip(previous[n].summary, to: max(1, nameWidth - TerminalText.width(suffix))) + suffix : ""
                    left.append(ui.muted((n == 0 ? "    " + cell(age(release.date, now: now), 23) : String(repeating: " ", count: 27)) + TerminalText.clip(history, to: nameWidth)))
                }
                left.append("")
            }
        }
        let provenance = [company(companyID), model.releaseDate ?? "—", age(model.exactDate, now: now)].filter { !$0.isEmpty }.joined(separator: " · ")
        let pinned = [ui.style(TerminalText.clean(model.name), "1"), ui.muted(provenance), ""]
        let body = details(model, width: rightWidth, ui: ui), visibleRows = paneRows - pinned.count
        let limit = max(0, body.count - visibleRows), offset = min(limit, max(0, selection.detailOffset))
        let right = pinned + body.dropFirst(offset).prefix(visibleRows)
        for i in 0..<paneRows { lines.append(cell(i < left.count ? left[i] : "", leftWidth) + ui.track(" │ ") + (i < right.count ? right[i] : "")) }
        lines += [ui.rule, ui.footer(selection.isCompanyPage
            ? "↑↓ model · ← back · space detail · c compare · s card · S lab · q quit"
            : "↑↓ batch · → company · space detail · c compare · s card · S lab · q quit", notice: notice)]
        return TimelineFrame(text: ui.finish(lines), scrollLimit: limit)
    }
}
