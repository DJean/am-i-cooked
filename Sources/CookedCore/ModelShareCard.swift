import Foundation
import CoreGraphics

public enum ModelShareCard {
    public static func save(catalog: ModelCatalog, companies: [ModelCompany], timeline: TimelineState,
                            comparison: ModelCompareState? = nil, companyCard: Bool = false, mark: Data? = nil, now: Date = Date(),
                            directory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) throws -> URL {
        try CardCanvas.save(png(catalog: catalog, companies: companies, timeline: timeline, comparison: comparison,
                               companyCard: companyCard, mark: mark, now: now), prefix: "cooked-models", now: now, directory: directory)
    }
    public static func png(catalog: ModelCatalog, companies: [ModelCompany], timeline: TimelineState,
                           comparison: ModelCompareState? = nil, companyCard: Bool = false, mark: Data? = nil, now: Date = Date()) throws -> Data {
        let note = catalog.priceError != nil || catalog.priceLoading ? "models.dev · prices incomplete" : "models.dev"
        if let comparison, !comparison.searching, comparison.selectedIDs.count >= 2 {
            return try compare(ModelComparison(catalog: catalog, state: comparison), now: now, note: note)
        }
        let models = TimelineRenderer.models(catalog: catalog, companies: companies)
        var selected = timeline; selected.reconcile(models: models)
        guard let model = models.first(where: { $0.id == selected.selectedID }) else { throw CardError(message: "Nothing to put on a card yet.") }
        let id = String(model.id.prefix { $0 != "/" }), name = companies.first { $0.id == id }?.name ?? id
        return try companyCard ? company(models: models, id: id, name: name, now: now, note: note, mark: mark)
            : profile(model: model, company: name, now: now, note: note, mark: mark)
    }
    static func wrap(_ value: String, columns: Int) -> [String] { TerminalText.wrap(value, to: columns) }
    static func priceRows(_ price: CatalogPrice?) -> [(String, String)] {
        var rows = [("Input", ModelFigure.rate(price?.input)), ("Output", ModelFigure.rate(price?.output)),
                    ("Cache read", ModelFigure.rate(price?.cacheRead)), ("Cache write", ModelFigure.rate(price?.cacheWrite))]
        for tier in price?.distinctTiers ?? [] {
            rows.append((tier.label, ""))
            rows += [("  Input", ModelFigure.rate(tier.input)), ("  Output", ModelFigure.rate(tier.output)),
                     ("  Cache read", ModelFigure.rate(tier.cacheRead)), ("  Cache write", ModelFigure.rate(tier.cacheWrite))]
        }
        return rows
    }
    private enum Line {
        case hero(String), caption(String), section(String), pair(String, String), body(String), gap, rule
        var advance: CGFloat { switch self { case .hero: 38; case .caption: 20; case .section: 30; case .pair: 21; case .body: 18; case .gap: 14; case .rule: 16 } }
    }
    private static func render(_ lines: [Line], now: Date, ion: Bool, note: String, mark: Data?) throws -> Data {
        let mask = mark.flatMap(LabMarks.mask), last = 76 + lines.reduce(CGFloat(0)) { $0 + $1.advance }
        let footerRule = last + 26
        let card = try CardCanvas(width: 600, height: footerRule + 32 + 30, now: now, palette: ion ? .ion : .standard)
        if let mask { card.logo(mask) }
        var y: CGFloat = 76, inHeader = true
        for line in lines {
            y += line.advance
            let indent: CGFloat = inHeader && mask != nil ? 58 : 0
            switch line {
            case .hero(let text): card.text(text, 44 + indent, y, 26, card.accent, maxWidth: 512 - indent, minimumSize: 14, glow: true, bold: true)
            case .caption(let text): card.text(text, 44 + indent, y, 10, card.muted, maxWidth: 512 - indent)
            case .section(let text): inHeader = false; card.text(text.uppercased(), 44, y, 9, card.faint, maxWidth: 512, kern: 2)
            case .pair(let label, let value):
                inHeader = false
                card.text(label, 44, y, 10.5, card.muted, maxWidth: value.isEmpty ? 512 : 307)
                card.text(value, 556, y, 11.5, card.white, maxWidth: 205, right: true)
            case .body(let text): inHeader = false; card.text(text, 44, y, 10, card.muted, maxWidth: 512)
            case .rule: inHeader = false; card.rule(y)
            case .gap: inHeader = false
            }
        }
        return try card.png(note: note, footerRule: footerRule)
    }
    static func profile(model: CatalogModel, company: String, now: Date, note: String, mark: Data? = nil) throws -> Data {
        let age = TimelineRenderer.age(model.exactDate, now: now)
        var lines: [Line] = [.hero(model.name), .caption(company + " · released " + (model.releaseDate ?? "—") + (age.isEmpty ? "" : " · " + age)), .gap]
        if let summary = model.description, !summary.isEmpty { lines += wrap(summary, columns: 62).map(Line.body) + [.gap] }
        for fact in model.facts { lines += wrap(fact, columns: 62).map(Line.body) }
        lines += [.section("PRICE  USD / 1M"), .pair("Source", model.priceSource ?? "—")]
        lines += priceRows(model.cost).map { .pair($0.0, $0.1) }
        lines.append(.section("PROVIDERS"))
        if model.deployments?.isEmpty != false { lines.append(.body("—")) }
        var host = ""
        for deployment in model.deployments ?? [] {
            if host != deployment.host { host = deployment.host; lines.append(.body(host)) }
            lines += wrap(deployment.modelID, columns: 60).map { .body("  " + $0) }
        }
        lines.append(.section("BENCHMARKS"))
        if model.benchmarks?.isEmpty != false { lines.append(.body("—")) }
        for benchmark in model.benchmarks ?? [] {
            lines += wrap(benchmark.name, columns: 44).enumerated().map { .pair($0.element, $0.offset == 0 ? ModelFigure.score(benchmark.score) : "") }
        }
        return try render(lines, now: now, ion: model.isNewRelease(now: now), note: note, mark: mark)
    }
    static func company(models: [CatalogModel], id: String, name: String, now: Date, note: String, mark: Data? = nil) throws -> Data {
        let releases = TimelineRelease.grouped(models: models.filter { $0.id.hasPrefix(id + "/") }).filter { $0.date != nil }
        let shown = Array(releases.prefix(6))
        var lines: [Line] = [.hero(name), .caption(ReleaseCadence(models: models, companyID: id, now: now).label), .section("RELEASES  \(shown.count) OF \(releases.count) GROUPS")]
        for release in shown {
            lines.append(.pair(release.models[0].releaseDate ?? "—", TimelineRenderer.age(release.date, now: now)))
            for model in release.models { lines += wrap(model.name, columns: 60).map { .body("  " + $0) } }
            lines.append(.gap)
        }
        return try render(lines, now: now, ion: shown.contains { $0.models[0].isNewRelease(now: now) }, note: note, mark: mark)
    }
    static func compare(_ comparison: ModelComparison, now: Date, note: String) throws -> Data {
        let n = comparison.ids.count, modelWidth: CGFloat = 160, labelWidth: CGFloat = 210
        let width = 88 + labelWidth + CGFloat(n) * modelWidth
        let headings = comparison.names.enumerated().map { wrap($0.element + ($0.offset == comparison.baseline ? " *" : ""), columns: 20) }
        let headerHeight = CGFloat(headings.map(\.count).max() ?? 1) * 18
        let rows = comparison.rows.map { row in wrap(row.name + (row.condition.isEmpty ? "" : " · " + row.condition), columns: 28) }
        let cells = comparison.rows.map { row in comparison.ids.indices.map { i -> ([String], String) in
            let delta = i == comparison.baseline || row.values[i] == "—" ? "" : " (" + row.changes[i] + ")"
            let available = max(4, 20 - delta.count * 2 / 3)
            return (wrap(row.values[i], columns: available), delta)
        } }
        let heights = rows.indices.map { max(rows[$0].count, cells[$0].map { $0.0.count }.max() ?? 1) * 18 + 6 }
        let bodyTop: CGFloat = 186 + headerHeight
        let legend = bodyTop + CGFloat(heights.reduce(0, +)) + 26, footerRule = legend + 26
        let card = try CardCanvas(width: width, height: footerRule + 62, now: now)
        card.text("COMPARE", 44, 114, 26, card.accent, maxWidth: width - 88, glow: true, bold: true)
        card.text("\(n) models · * is the reference", 44, 134, 10, card.muted)
        card.text("Metric", 44, 166, 10, card.muted)
        for (i, heading) in headings.enumerated() {
            for (j, text) in heading.enumerated() {
                card.text(text, 44 + labelWidth + CGFloat(i + 1) * modelWidth, 166 + CGFloat(j) * 18, 11, card.white,
                          maxWidth: modelWidth - 12, right: true, bold: i == comparison.baseline)
            }
        }
        card.rule(bodyTop - 16)
        var y = bodyTop
        for i in rows.indices {
            for (j, label) in rows[i].enumerated() { card.text(label, 44, y + CGFloat(j) * 18, 10.5, card.muted, maxWidth: labelWidth - 12) }
            for column in comparison.ids.indices {
                let (values, delta) = cells[i][column], end = 44 + labelWidth + CGFloat(column + 1) * modelWidth
                let changeWidth = card.lineWidth(card.line(delta, 8, card.faint))
                for (j, value) in values.enumerated() { card.text(value, end - changeWidth, y + CGFloat(j) * 18, 11.5, card.white, maxWidth: modelWidth - changeWidth - 12, right: true) }
                card.text(delta, end, y, 8, card.faint, maxWidth: max(1, changeWidth), right: true)
            }
            y += CGFloat(heights[i])
        }
        card.text("% change vs * · — missing/ambiguous · / multiple scores", 44, legend, 9, card.muted, maxWidth: width - 88)
        return try card.png(note: note, footerRule: footerRule)
    }
}
