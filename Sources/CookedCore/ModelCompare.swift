import Foundation

public struct ModelCompareState: Sendable {
    public var query = ""
    public var selectedIDs: [String] = []
    public var baselineID: String?
    public var cursor = 0
    public var searching = true
    public var selectedRow = 0
    public var modelOffset = 0
    public init() {}
    public mutating func reconcile(catalog: ModelCatalog) {
        let valid = Set(catalog.models.map(\.id))
        selectedIDs.removeAll { !valid.contains($0) }
        if let baselineID, !selectedIDs.contains(baselineID) { self.baselineID = nil }
        cursor = min(max(0, cursor), max(0, matches(catalog).count - 1))
        if selectedIDs.count < 2 { searching = true }
        selectedRow = 0; modelOffset = min(modelOffset, max(0, selectedIDs.count - 2))
    }
    public func effectiveBaseline() -> String? {
        baselineID.flatMap { selectedIDs.contains($0) ? $0 : nil } ?? selectedIDs.first
    }
    public func matches(_ catalog: ModelCatalog) -> [CatalogModel] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return catalog.models.filter { model in
            let haystack = (model.name + " " + model.id).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }.sorted {
            if $0.releaseDate != $1.releaseDate { return ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
            return $0.id < $1.id
        }
    }
    // True means close the overlay. Printable text is never treated as a global shortcut here.
    public mutating func handle(_ key: TerminalKey, catalog: ModelCatalog, scrollLimit: Int, modelLimit: Int) -> Bool {
        if searching {
            switch key {
            case .text(let value): query += value; cursor = 0
            case .backspace:
                if !query.isEmpty { query.removeLast() }
                else if let removed = selectedIDs.popLast(), baselineID == removed { baselineID = nil }
                cursor = 0
            case .clear: query = ""; cursor = 0
            case .up: cursor = max(0, cursor - 1)
            case .down: cursor = min(max(0, matches(catalog).count - 1), cursor + 1)
            case .enter:
                let results = matches(catalog)
                if !results.isEmpty {
                    let id = results[min(max(0, cursor), results.count - 1)].id
                    if selectedIDs.contains(id) {
                        selectedIDs.removeAll { $0 == id }
                        if baselineID == id { baselineID = nil }
                    }
                    else { selectedIDs.append(id) }
                }
                if !query.isEmpty { query = ""; cursor = 0 }
            case .tab: if selectedIDs.count >= 2 { searching = false; selectedRow = 0; modelOffset = 0 }
            case .escape: return true
            default: break
            }
        } else {
            switch key {
            case .escape, .text("c"), .text("C"): searching = true
            case .text("b"), .text("B"):
                if let baseline = effectiveBaseline(), let index = selectedIDs.firstIndex(of: baseline) {
                    baselineID = selectedIDs[(index + 1) % selectedIDs.count]
                }
            case .up: selectedRow = max(0, min(selectedRow, scrollLimit) - 1)
            case .down: selectedRow = min(scrollLimit, selectedRow + 1)
            case .previous: modelOffset = max(0, min(modelOffset, modelLimit) - 1)
            case .next: modelOffset = min(modelLimit, modelOffset + 1)
            default: break
            }
        }
        return false
    }
}

private struct BenchmarkCondition: Hashable {
    let name: String
    let fields: [String]
    init(_ score: ModelBenchmark) {
        name = TerminalText.clean(score.name).trimmingCharacters(in: .whitespacesAndNewlines)
        fields = [score.version, score.variant, score.metric, score.dataset, score.harness].map {
            TerminalText.clean($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

struct ModelComparison {
    struct Row {
        let name: String
        let condition: String
        let values: [String]
        let changes: [String]
    }
    let ids: [String]
    let models: [CatalogModel?]
    let baseline: Int
    let names: [String]
    let rows: [Row]

    init(catalog: ModelCatalog, state: ModelCompareState) {
        let ids = state.selectedIDs
        let models = ids.map { id in catalog.models.first { $0.id == id } }
        let baseline = ids.firstIndex(of: state.effectiveBaseline() ?? "") ?? 0
        let plainNames = models.enumerated().map { index, model in TerminalText.clean(model?.name ?? ids[index]) }
        let groups = Dictionary(grouping: ids.indices, by: { plainNames[$0] })
        let names = ids.indices.map { index in
            let duplicate = Set((groups[plainNames[index]] ?? []).map { ids[$0] }).count > 1
            return plainNames[index] + (duplicate ? " (" + TerminalText.clean(ids[index]) + ")" : "")
        }
        let scores = models.map { model in
            Dictionary(grouping: model?.benchmarks ?? [], by: BenchmarkCondition.init).mapValues { Array(Set($0.map(\.score).filter(\.isFinite))).sorted() }
        }
        let keys = Set(scores.flatMap { $0.keys }).sorted {
            $0.name == $1.name ? $0.fields.lexicographicallyPrecedes($1.fields) : $0.name < $1.name
        }
        // Show only the condition fields needed to distinguish rows with the same benchmark name.
        let conditions = keys.map { key in
            let variants = keys.filter { $0.name == key.name }
            let conditions = key.fields.indices.filter { index in Set(variants.map { $0.fields[index] }).count > 1 }
            let details = conditions.map { index in
                let value = key.fields[index]
                if index == 0 { return value.isEmpty ? "version —" : value }
                return value.isEmpty ? ["", "variant", "metric", "data", "harness"][index] + " —" : value
            }
            return details.joined(separator: " · ")
        }
        let values = keys.map { key in scores.map { reported in
            let values = reported[key] ?? []
            return values.isEmpty ? "—" : values.map(ModelFigure.score).joined(separator: " / ")
        } }
        let changes = keys.map { key in scores.map { reported -> String in
            guard scores.indices.contains(baseline), let base = scores[baseline][key], base.count == 1, base[0] != 0,
                  let value = reported[key], value.count == 1 else { return "—" }
            return ModelFigure.delta(value[0], base[0])
        } }
        self.ids = ids; self.models = models; self.baseline = baseline; self.names = names
        var rows: [Row] = []
        func numeric(_ name: String, _ values: [Double?], formatted: [String]) {
            guard values.contains(where: { $0 != nil }) else { return }
            let base = values.indices.contains(baseline) ? values[baseline] : nil
            rows.append(Row(name: name, condition: "", values: formatted, changes: values.map { ModelFigure.delta($0, base) }))
        }
        for (name, path) in [("Context", \CatalogModel.Limits.context), ("Max output", \CatalogModel.Limits.output)] {
            let values = models.map { $0?.limits?[keyPath: path].flatMap { $0 > 0 ? $0 : nil } }
            numeric(name, values.map { $0.map(Double.init) }, formatted: values.map(ModelFigure.tokens))
        }
        for (name, path) in [("Input", \CatalogPrice.input), ("Output", \CatalogPrice.output), ("Cache read", \CatalogPrice.cacheRead), ("Cache write", \CatalogPrice.cacheWrite)] {
            let values = models.map { $0?.cost?[keyPath: path] }
            numeric(name + " $/1M", values, formatted: values.map(ModelFigure.rate))
        }
        rows += keys.indices.map { Row(name: keys[$0].name, condition: conditions[$0], values: values[$0], changes: changes[$0]) }
        self.rows = rows
    }
}

public struct CompareFrame {
    public var text: String
    public var scrollLimit = 0
    public var modelLimit = 0
}

public enum ModelCompareRenderer {
    public static func frame(catalog: ModelCatalog, state: ModelCompareState, rows: Int, columns: Int,
                             color: Bool, notice: String? = nil, now: Date) -> CompareFrame {
        let width = min(104, max(1, columns - 2)), budget = max(1, rows - 1)
        guard columns >= 80, rows >= 21 else {
            return CompareFrame(text: TerminalChrome.tooSmall(rows: rows, columns: columns, minimumRows: 21))
        }
        let ui = TerminalChrome(width: width, color: color)
        var lines = ui.header(now: now, models: true, state: catalog.priceError != nil ? "prices incomplete" : nil)
        func cell(_ text: String, _ n: Int, right: Bool = false) -> String { TerminalText.pad(TerminalText.clip(text, to: n), to: n, left: right) }
        func finish(_ status: String, scroll: Int = 0, models: Int = 0, legend: String? = nil) -> CompareFrame {
            lines += Array(repeating: "", count: max(0, budget - lines.count - (legend == nil ? 2 : 3)))
            if let legend { lines.append(ui.muted(legend)) }
            lines += [ui.rule, ui.footer(status, notice: notice)]
            return CompareFrame(text: ui.finish(lines), scrollLimit: scroll, modelLimit: models)
        }
        if state.searching {
            var picks = state.selectedIDs.map { id in "[" + TerminalText.clean(catalog.models.first { $0.id == id }?.name ?? id) + "] " }
            let query = TerminalText.clean(state.query)
            var hidden = 0
            while !picks.isEmpty && TerminalText.width(picks.joined() + query) + 14 > width { picks.removeFirst(); hidden += 1 }
            let prefix = ui.muted("Compare  ") + (hidden > 0 ? ui.muted("+\(hidden) ") : "") + ui.style(picks.joined(), "38;5;72")
            let room = max(1, width - TerminalText.width(prefix) - 1)
            let shownQuery = TerminalText.clip(query, to: room)
            lines += [prefix + shownQuery + ui.style("▌", "38;5;73"), ""]
            let results = state.matches(catalog), capacity = max(1, budget - lines.count - 2)
            let cursor = min(max(0, state.cursor), max(0, results.count - 1)), start = max(0, cursor - capacity + 1)
            if results.isEmpty { lines.append(ui.muted("No model matches.")) }
            for i in start..<min(results.count, start + capacity) {
                let m = results[i], count = m.benchmarks?.count ?? 0
                let suffix = (m.releaseDate ?? "—") + " · \(count) \(count == 1 ? "score" : "scores")"
                let marker = i == cursor ? ui.style("▸ ", "38;5;73") : "  "
                let pick = state.selectedIDs.contains(m.id) ? ui.style("✓ ", "38;5;72") : "  "
                lines.append(marker + pick + cell(ui.style(TerminalText.clean(m.name), i == cursor ? "1" : "0"), width - TerminalText.width(suffix) - 6) + "  " + ui.muted(suffix))
            }
            return finish("⏎ pick · ⌫ unpick · tab compare · esc close")
        }
        let comparison = ModelComparison(catalog: catalog, state: state), n = comparison.ids.count
        guard n >= 2 else { lines.append(ui.muted("Choose at least 2 models.")); return finish("c edit · q quit") }
        let visible = min(max((width - 34) / 18, 2), n), labelWidth = width - visible * 18
        let modelLimit = max(0, n - visible), start = min(max(0, state.modelOffset), modelLimit), indices = start..<(start + visible)
        let header = indices.map { i -> String in
            let mark = i == comparison.baseline ? " *" : ""
            let name = TerminalText.clip(comparison.names[i], to: 18 - mark.count) + mark
            return ui.style(cell(name, 18, right: true), i == comparison.baseline ? "1" : "0")
        }.joined()
        lines += [cell("Metric", labelWidth) + header, ui.rule]
        let offscreen = !indices.contains(comparison.baseline)
        let capacity = max(1, budget - lines.count - 3 - (offscreen ? 1 : 0))
        let selected = min(max(0, state.selectedRow), max(0, comparison.rows.count - 1)), first = max(0, selected - capacity + 1)
        for i in first..<min(comparison.rows.count, first + capacity) {
            let row = comparison.rows[i]
            var label = row.name
            if !row.condition.isEmpty {
                let suffix = " · " + TerminalText.clip(row.condition, to: max(1, labelWidth / 2))
                label = TerminalText.clip(label, to: labelWidth - TerminalText.width(suffix) - 1) + suffix
            }
            let values = indices.map { column -> String in
                let change = column == comparison.baseline || row.values[column] == "—" ? "" : " (" + row.changes[column] + ")"
                let value = TerminalText.clip(row.values[column], to: max(1, 18 - TerminalText.width(change)))
                return String(repeating: " ", count: max(0, 18 - TerminalText.width(value + change))) + value + ui.muted(change)
            }.joined()
            lines.append(ui.style(cell(label, labelWidth), i == selected ? "1" : "38;5;245") + values)
        }
        lines += Array(repeating: "", count: max(0, budget - lines.count - 3 - (offscreen ? 1 : 0)))
        if offscreen { lines.append(ui.muted("ref: " + comparison.names[comparison.baseline])) }
        return finish("↑↓ rows · ←→ models · b reference · c edit · s card · q quit",
                      scroll: max(0, comparison.rows.count - 1), models: modelLimit,
                      legend: "% change vs * · — missing/ambiguous · / multiple scores")
    }
}
