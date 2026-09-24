import Foundation
import Darwin

public enum Format {
    public static func money(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    public static func cost(_ value: Double) -> String { value > 0 && value < 0.01 ? "<$0.01" : money(value) }
    public static func compact(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        for (divisor, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where abs(value) >= divisor {
            return String(format: "%.1f%@", locale: Locale(identifier: "en_US_POSIX"), value / divisor, suffix)
        }
        return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    public static func modelName(_ id: String) -> String {
        let name = id.hasPrefix("claude-") ? String(id.dropFirst(7)) : id
        var parts: [String] = []
        for part in name.split(separator: "-").map(String.init) {
            if part.range(of: "^[0-9]{8}$|^v1", options: .regularExpression) != nil { continue }
            if let last = parts.last, last.last?.isNumber == true, part.allSatisfy(\.isNumber) {
                parts[parts.count - 1] += "." + part
            } else { parts.append(part) }
        }
        var result = parts.joined(separator: " ").capitalized
            .replacingOccurrences(of: "(?<=[0-9])P(?=[0-9])", with: ".", options: .regularExpression)
        for (from, to) in [("Gpt", "GPT"), ("Glm", "GLM"), ("Minimax", "MiniMax"), ("Deepseek", "DeepSeek")] {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    public static func count(_ value: Int) -> String {
        for (divisor, suffix) in [(1_000_000_000.0, "B"), (1_000_000.0, "M"), (1_000.0, "K")] {
            if abs(Double(value)) >= divisor { return String(format: "%.1f%@", locale: Locale(identifier: "en_US_POSIX"), Double(value) / divisor, suffix) }
        }
        return String(value)
    }

    public static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", min(9999, max(0, value.isFinite ? value : 0)))
    }

    public static func reset(_ date: Date, now: Date) -> String {
        guard date > now else { return "resetting" }
        let calendar = Calendar.current
        let pattern = calendar.isDate(date, inSameDayAs: now) ? "HH:mm"
            : date < calendar.date(byAdding: .day, value: 7, to: now)! ? "EEE HH:mm" : "MMM d HH:mm"
        return "reset " + dateText(date, pattern)
    }

    static func dateText(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

// Sanitize external text before styling; only our own SGR escapes reach the terminal.
enum TerminalText {
    private static let localeReady: Bool = { setlocale(LC_CTYPE, "UTF-8") != nil }()
    static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .format
                && $0.properties.generalCategory != .lineSeparator && $0.properties.generalCategory != .paragraphSeparator
        }))
    }

    static func characterWidth(_ character: Character) -> Int {
        _ = localeReady
        let scalars = character.unicodeScalars
        if scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value == 0x20E3 }) { return 2 }
        return scalars.reduce(0) {
            let width = Int(wcwidth(wchar_t($1.value)))
            return $0 + (width < 0 ? ($1.isASCII ? 0 : 2) : width)
        }
    }

    static func wrap(_ text: String, to width: Int) -> [String] {
        guard width > 0 else { return [] }
        var lines: [String] = [], line = ""
        for character in clean(text) {
            if self.width(line) + characterWidth(character) > width && !line.isEmpty {
                if let split = line.lastIndex(of: " "), split != line.startIndex {
                    lines.append(String(line[..<split])); line = String(line[line.index(after: split)...])
                } else { lines.append(line); line = "" }
            }
            line.append(character)
        }
        return lines + [line]
    }

    static func tokens(_ text: String) -> [(String, Int)] {
        var output: [(String, Int)] = [], index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\u{1B}", let end = text[index...].firstIndex(of: "m") {
                let next = text.index(after: end)
                output.append((String(text[index..<next]), 0)); index = next
            } else {
                let character = text[index]
                output.append((String(character), characterWidth(character))); index = text.index(after: index)
            }
        }
        return output
    }

    static func width(_ text: String) -> Int { tokens(text).reduce(0) { $0 + $1.1 } }
    static func clip(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        let pieces = tokens(text)
        guard pieces.reduce(0, { $0 + $1.1 }) > limit else { return text }
        var result = "", used = 0
        for (piece, width) in pieces {
            guard used + width <= limit - 1 else { break }
            result += piece; used += width
        }
        return result + "…" + (text.contains("\u{1B}") ? "\u{1B}[0m" : "")
    }

    static func pad(_ text: String, to width: Int, left: Bool = false) -> String {
        let spaces = String(repeating: " ", count: max(0, width - self.width(text)))
        return left ? spaces + text : text + spaces
    }
}

public enum ModelFigure {
    private static func decimal(_ value: Double, digits: Int) -> String {
        guard value.isFinite else { return "—" }
        if abs(value) >= 1e9 || (value != 0 && abs(value) < 1e-4) {
            return String(format: "%.1e", locale: Locale(identifier: "en_US_POSIX"), value).lowercased()
        }
        let text = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
        return text.contains(".") ? text.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression) : text
    }
    public static func score(_ value: Double) -> String { decimal(value, digits: 1) }
    public static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return "$" + decimal(value, digits: 4)
    }
    public static func tokens(_ value: Int?) -> String {
        guard let value, value > 0 else { return "—" }
        if value < 1000 { return String(value) }
        for (unit, suffix) in [(1_000_000, "M"), (1_048_576, "M"), (1000, "K"), (1024, "K")]
        where value % unit == 0 && value / unit < 1000 { return "\(value / unit)" + suffix }
        return decimal(Double(value) / (value >= 1_000_000 ? 1e6 : 1e3), digits: value >= 1_000_000 ? 2 : 1) + (value >= 1_000_000 ? "M" : "K")
    }
    public static func delta(_ value: Double?, _ reference: Double?) -> String {
        guard let value, let reference, reference != 0 else { return "—" }
        let delta = (value - reference) / abs(reference) * 100
        guard delta.isFinite else { return "—" }
        let rounded = abs(delta) < 1e9 ? (delta * 10).rounded(.toNearestOrEven) / 10 : delta
        return (rounded > 0 ? "+" : "") + (rounded == 0 ? "0" : decimal(rounded, digits: 1)) + "%"
    }
}

struct TerminalChrome {
    let width: Int
    let color: Bool
    func style(_ text: String, _ code: String = "0") -> String { color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
    func muted(_ text: String) -> String { style(text, "38;5;245") }
    func track(_ text: String) -> String { style(text, "38;5;238") }
    var rule: String { track(String(repeating: "─", count: width)) }
    func ends(_ left: String, _ right: String) -> String {
        guard width - TerminalText.width(left) - TerminalText.width(right) >= 2 else { return TerminalText.clip(left, to: width) }
        return TerminalText.pad(left, to: width - TerminalText.width(right)) + right
    }
    func header(now: Date, models: Bool, live: Bool = true, new: Bool = false, state: String? = nil) -> [String] {
        var lines = [ends(style("✻  AM I COOKED?", "1;38;5;73"), muted(Format.dateText(now, "EEE MMM d · HH:mm")))]
        if live {
            let tabs = style("Usage", models ? "38;5;238" : "1") + track("  ·  ")
                + style("Models", models ? "1" : "38;5;238") + (!models && new ? style(" NEW", "38;5;167") : "")
            lines.append(ends(tabs, state.map(muted) ?? ""))
        }
        return lines + [rule]
    }
    func footer(_ status: String, notice: String? = nil) -> String {
        ends(notice.map { style(TerminalText.clean($0), "38;5;73") } ?? muted(status), track("v" + Build.version))
    }
    func finish(_ lines: [String]) -> String { lines.map { TerminalText.clip($0, to: width) }.joined(separator: "\n") }
    static func tooSmall(rows: Int, columns: Int, minimumRows: Int) -> String {
        let text: String
        if columns < 80 && rows < minimumRows { text = "too small · current \(columns)×\(rows) · minimum 80×\(minimumRows)" }
        else if columns < 80 { let n = 80 - columns; text = "too narrow · add \(n) \(n == 1 ? "column" : "columns") (\(columns)→80)" }
        else { let n = max(0, minimumRows - rows); text = "too short · add \(n) \(n == 1 ? "row" : "rows") (\(rows)→\(minimumRows))" }
        return TerminalText.clip("AM I COOKED? · terminal " + text, to: min(104, max(1, columns - 2)))
    }
}

public enum DashboardRenderer {
    public static func render(snapshots: [ProviderSnapshot], now: Date, live: Bool,
                              expanded: Bool, maxRows: Int, maxColumns: Int,
                              notice: String?, loading: Bool, color: Bool = true, newModels: Bool = false) -> String {
        let width = min(max(maxColumns - 2, 1), 104), budget = max(0, maxRows - 1)
        let ui = TerminalChrome(width: width, color: color)
        let hasDetails = snapshots.contains { !$0.details.isEmpty }, expanded = expanded && hasDetails
        let usable = snapshots.contains { !$0.metrics.isEmpty }
        let providers = snapshots.enumerated().sorted {
            $0.element.metrics.isEmpty == $1.element.metrics.isEmpty ? $0.offset < $1.offset : !$0.element.metrics.isEmpty
        }.map(\.element)
        let totals = [snapshots.map(\.todayUSD), snapshots.map(\.weekUSD), snapshots.map(\.monthUSD)].map { values -> String? in
            let values = values.compactMap { $0 }; return values.isEmpty ? nil : Format.money(values.reduce(0, +))
        }
        func index(_ period: MetricPeriod) -> Int { switch period { case .today: 0; case .week: 1; case .month: 2 } }
        func costs(_ metrics: [Metric]) -> [String?] {
            var values: [String?] = [nil, nil, nil]
            for metric in metrics where metric.progress == nil {
                if let period = metric.period { values[index(period)] = TerminalText.clean(metric.value) }
            }
            return values
        }
        let widths = (0..<3).map { column in ([totals] + providers.map { costs($0.metrics) }).map { TerminalText.width($0[column] ?? "") }.max() ?? 0 }
        let labelWidth = max(15, providers.flatMap(\.metrics).filter { $0.period == nil || $0.progress != nil }
            .map { TerminalText.width(TerminalText.clean($0.label)) }.max() ?? 0)
        func usage(_ values: [String?], bold: Bool = false) -> String {
            (0..<3).compactMap { i in values[i].map {
                ui.muted(["Today", "Week", "Month"][i]) + " " + ui.style(TerminalText.pad($0, to: widths[i], left: true), bold ? "1" : "0")
            } }.joined(separator: ui.muted(" · "))
        }
        func row(_ metric: Metric, detail: Bool = false) -> String {
            let label = TerminalText.pad(TerminalText.clip(TerminalText.clean(metric.label), to: detail ? 20 : labelWidth), to: detail ? 20 : labelWidth)
            var value = TerminalText.clean(metric.value)
            if let progress = metric.progress {
                let p = min(1, max(0, progress.isFinite ? progress : 0)), filled = Int((p * 12).rounded())
                value = ui.style(String(repeating: "█", count: filled), "38;5;" + (p < 0.7 ? "72" : p < 0.9 ? "179" : "167"))
                    + ui.track(String(repeating: "░", count: 12 - filled)) + "  " + value
            }
            if let detail = metric.detail { value += ui.muted(" · " + TerminalText.clean(detail)) }
            return (detail ? "    " : "  ") + ui.muted(label) + "  " + value
        }
        func screen(_ allocations: [Int]) -> [String] {
            var lines = ui.header(now: now, models: false, live: live, new: newModels)
            if providers.isEmpty { lines += ["", ui.muted(loading ? "Loading usage..." : "No usage available. Check network or sign in.")] }
            for (i, provider) in providers.enumerated() {
                if !expanded { lines.append("") }
                var subtitle = provider.subtitle.map(TerminalText.clean) ?? ""
                if expanded && !provider.details.isEmpty { subtitle += (subtitle.isEmpty ? "" : " · ") + "\(allocations[i])/\(provider.details.count) models" }
                lines.append(ui.style(TerminalText.clean(provider.title), "1") + (subtitle.isEmpty ? "" : ui.muted(" · " + subtitle)))
                if expanded { lines += provider.metrics.map { row($0) } }
                else {
                    lines += provider.metrics.filter { $0.progress != nil || $0.period == nil }.map { row($0) }
                    let amounts = usage(costs(provider.metrics))
                    if !amounts.isEmpty { lines.append("  " + ui.muted(TerminalText.pad("Usage", to: labelWidth)) + "  " + amounts) }
                }
                if expanded { lines += provider.details.prefix(allocations[i]).map { row($0, detail: true) } }
                lines += provider.notes.map { ui.muted("  · " + TerminalText.clean($0)) }
            }
            let hasTotals = totals.contains { $0 != nil }
            if usable && hasTotals { lines += ["", ui.style(TerminalText.pad("All agents", to: labelWidth + 2), "1") + "  " + usage(totals, bold: true)] }
            lines.append(ui.rule)
            if hasTotals { lines.append(ui.muted("estimates use local usage × public API rates, not billed spend")) }
            let status = !live ? "snapshot" : loading ? "q quit" : (hasDetails ? "space \(expanded ? "close" : "details") · " : "") + "s share · q quit"
            lines.append(ui.footer(status, notice: live && !loading ? notice : nil))
            return lines
        }
        var allocations = Array(repeating: 0, count: providers.count)
        let base = screen(allocations).count
        if maxColumns < 80 || base > budget { return TerminalChrome.tooSmall(rows: maxRows, columns: maxColumns, minimumRows: base + 1) }
        if expanded {
            var remaining = budget - base
            while remaining > 0 {
                var added = false
                for i in providers.indices where remaining > 0 && allocations[i] < providers[i].details.count {
                    allocations[i] += 1; remaining -= 1; added = true
                }
                if !added { break }
            }
        }
        return ui.finish(screen(allocations))
    }
}
