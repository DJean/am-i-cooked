import XCTest
import ImageIO
@testable import CookedCore

final class RenderingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func panel(_ snapshots: [ProviderSnapshot] = [], expanded: Bool = false, rows: Int = 40,
                       columns: Int = 106, notice: String? = nil, loading: Bool = false, live: Bool = true, color: Bool = false) -> String {
        DashboardRenderer.render(snapshots: snapshots, now: now, live: live, expanded: expanded,
                                 maxRows: rows, maxColumns: columns, notice: notice, loading: loading, color: color)
    }
    private func provider(_ title: String, month: Double? = 3, details: Int = 0) -> ProviderSnapshot {
        ProviderSnapshot(title: title, todayUSD: 1, monthUSD: month, monthTokens: 12_345, monthRequests: 4,
                         metrics: [Metric("Current window", "42%", progress: 0.42), Metric("Today", "$1.00", period: .today),
                                   Metric("Month", "$3.00", period: .month)],
                         details: (0..<details).map { Metric("\(title)-model-\($0)", "$1.00") })
    }

    func testFormattingAndResetBoundaries() {
        XCTAssertEqual(Format.money(0), "$0.00")
        XCTAssertEqual(Format.cost(0.009), "<$0.01")
        XCTAssertEqual(Format.money(.nan), "—")
        XCTAssertEqual(Format.count(1_234_567), "1.2M")
        XCTAssertEqual(Format.count(Int.min), "-9223372036.9B")
        XCTAssertEqual(Format.percent(-4), "0%")
        XCTAssertEqual(Format.percent(20_000), "9999%")
        XCTAssertEqual(Format.reset(now, now: now), "resetting")
        let midday = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        XCTAssertEqual(Format.reset(midday.addingTimeInterval(60), now: midday), "reset 12:01")
        XCTAssertTrue(Format.reset(midday.addingTimeInterval(8 * 86_400), now: midday).contains(Format.dateText(midday.addingTimeInterval(8 * 86_400), "MMM d")))
    }

    func testLoadingNoticeVersionAndUnavailableStates() {
        let loading = panel(loading: true)
        XCTAssertTrue(loading.contains("Loading usage..."))
        XCTAssertFalse(loading.contains("No usage"))
        XCTAssertTrue(loading.contains("q quit"))
        XCTAssertFalse(loading.contains("s share"))
        let unavailable = panel([ProviderSnapshot(title: "Offline", notes: ["network failed"])])
        XCTAssertTrue(unavailable.contains("network failed"))
        XCTAssertTrue(unavailable.contains("Offline"))
        let notice = panel([provider("Codex")], notice: "Saved ~/Downloads/card.png")
        XCTAssertTrue(notice.contains("Saved ~/Downloads/card.png"))
        XCTAssertFalse(notice.contains("s share"))
        XCTAssertTrue(notice.hasSuffix("v" + Build.version))
        XCTAssertEqual(TerminalText.width(notice.components(separatedBy: "\n").last!), 104)
        XCTAssertTrue(panel(live: false, color: true).contains("snapshot"))
        XCTAssertFalse(panel(live: false, color: false).contains("\u{1B}"))
    }

    func testTotalsAndCostsWithMissingPeriods() {
        var second = provider("Other", month: nil)
        second.todayUSD = nil; second.weekUSD = 5
        let rendered = panel([provider("Codex"), second])
        let total = rendered.components(separatedBy: "\n").first { $0.hasPrefix("All agents") }!
        XCTAssertTrue(total.contains("Today $1.00"))
        XCTAssertTrue(total.contains("Week $5.00"))
        XCTAssertTrue(total.contains("Month $3.00"))
        XCTAssertEqual(rendered.components(separatedBy: "\n").filter { $0.hasPrefix("  Usage ") }.count, 2)
        XCTAssertFalse(panel([provider("Codex", details: 20)]).contains("Codex-model"))
    }

    func testExpandedModelsRotateWithinRowBudget() {
        let snapshots = [provider("A", details: 30), provider("B", details: 30)]
        let baseline = panel(snapshots, expanded: true, rows: 20)
        XCTAssertTrue(baseline.contains("2/30 models"))
        XCTAssertTrue(baseline.contains("1/30 models"))
        XCTAssertTrue(baseline.contains("A-model-1"))
        XCTAssertTrue(baseline.contains("B-model-0"))
        XCTAssertFalse(baseline.contains("B-model-1"))
        XCTAssertLessThanOrEqual(baseline.components(separatedBy: "\n").count, 19)
        XCTAssertTrue(panel(snapshots, rows: 5).contains("terminal too short"))
        XCTAssertTrue(panel(columns: 79).contains("add 1 column"))
    }

    func testWideTextAndTerminalEscapeInjectionCannotWrap() {
        let wide = String(repeating: "界👩🏽‍💻🇨🇳é", count: 100)
        var snapshot = provider(wide)
        snapshot.subtitle = "\u{1B}[2J\n\r" + wide
        snapshot.notes = ["\u{1B}]0;title\u{7}\t" + wide]
        snapshot.details = [Metric(wide, wide)]
        let plain = panel([snapshot], expanded: true, columns: 80, notice: wide)
        XCTAssertFalse(plain.contains("\u{1B}"))
        XCTAssertFalse(plain.contains("\r"))
        for row in plain.components(separatedBy: "\n") { XCTAssertLessThanOrEqual(TerminalText.width(row), 78) }
        let colored = panel([snapshot], expanded: true, columns: 80, color: true)
        XCTAssertFalse(colored.contains("\u{1B}[2J"))
        XCTAssertFalse(colored.contains("\u{1B}]"))
        for row in colored.components(separatedBy: "\n") { XCTAssertLessThanOrEqual(TerminalText.width(row), 78) }
        XCTAssertEqual(TerminalText.width("界👩🏽‍💻🇨🇳é"), 7)
        XCTAssertEqual(TerminalText.clip("界界界", to: 4), "界…")
    }

    func testShareCardFiltersProvidersAndDoesNotOverwrite() throws {
        XCTAssertThrowsError(try ShareCardRenderer.png(snapshots: [ProviderSnapshot(title: "empty")])) {
            XCTAssertEqual($0.localizedDescription, "No monthly usage to share.")
        }
        let snapshot = provider("Codex", details: 3)
        let data = try ShareCardRenderer.png(snapshots: [snapshot], now: now, name: "Tester")
        XCTAssertEqual(data, try ShareCardRenderer.png(snapshots: [snapshot, ProviderSnapshot(title: "Hidden", todayUSD: 999)], now: now, name: "Tester"))
        let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 960)
        XCTAssertGreaterThan(properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0, 960)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try ShareCardRenderer.save(snapshots: [snapshot], now: now, name: "Tester", directory: directory)
        let second = try ShareCardRenderer.save(snapshots: [snapshot], now: now, name: "Tester", directory: directory)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix("-2.png"))
        XCTAssertEqual(try Data(contentsOf: first), data)
        XCTAssertEqual(PixelAvatar.pixels("Tester"), PixelAvatar.pixels("tester"))
        XCTAssertNotEqual(PixelAvatar.pixels("Tester"), PixelAvatar.pixels("Someone else"))
        XCTAssertNotEqual(PixelAvatar.hash("Tester"), PixelAvatar.hash("Someone else"))
    }
}
