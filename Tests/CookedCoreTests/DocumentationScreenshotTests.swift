import XCTest
import CoreGraphics
import CoreText
import ImageIO
@testable import CookedCore

/// Documentation images use the actual renderers and entirely invented data.
/// No provider, credential store, user name, cache, or network is accessed.
final class DocumentationScreenshotTests: XCTestCase {
    func testDocumentationScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["COOKED_DOC_SCREENSHOTS"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = ReleaseDates.parse("2026-09-24")!.addingTimeInterval(12 * 3600)
        let companies = ModelCompany.configured()
        let catalog = try ModelCatalog.decode(metadata: Data(Self.metadata.utf8), prices: Data(Self.prices.utf8),
                                              companies: companies, now: now)
        let snapshots = Self.snapshots
        let models = TimelineRenderer.models(catalog: catalog, companies: companies)
        var timeline = TimelineState()
        timeline.reconcile(models: models)
        let rows = 31, columns = 106
        let usage = DashboardRenderer.render(snapshots: snapshots, now: now, live: true, expanded: false,
            maxRows: rows, maxColumns: columns, notice: nil, loading: false, color: true, newModels: true)
        let expanded = DashboardRenderer.render(snapshots: snapshots, now: now, live: true, expanded: true,
            maxRows: rows, maxColumns: columns, notice: nil, loading: false, color: true, newModels: true)
        let home = TimelineRenderer.frame(catalog: catalog, companies: companies, state: timeline,
            now: now, rows: rows, columns: columns, loading: false, color: true).text
        var company = timeline
        company.handle(.next, models: models, scrollLimit: 0)
        let companyFrame = TimelineRenderer.frame(catalog: catalog, companies: companies, state: company,
            now: now, rows: rows, columns: columns, loading: false, color: true).text
        var comparison = ModelCompareState()
        comparison.selectedIDs = ["openai/demo-reasoner", "anthropic/demo-writer", "google/demo-flash"]
        let search = ModelCompareRenderer.frame(catalog: catalog, state: comparison,
            rows: 23, columns: columns, color: true, now: now).text
        comparison.searching = false
        let compare = ModelCompareRenderer.frame(catalog: catalog, state: comparison,
            rows: 23, columns: columns, color: true, now: now).text
        let frames = [("usage", usage), ("usage-details", expanded), ("models", home),
                      ("company", companyFrame), ("search", search), ("compare", compare)]
        for (name, frame) in frames {
            XCTAssertFalse(frame.contains("too small"), name)
            XCTAssertLessThanOrEqual(frame.split(separator: "\n", omittingEmptySubsequences: false).count, rows - 1)
            XCTAssertTrue(frame.contains("AM I COOKED?"), name)
            let png = try TerminalScreenshot.png(frame, columns: columns - 2, title: "cooked · " + name + " · synthetic data")
            try png.write(to: output.appendingPathComponent(name + ".png"))
        }
        XCTAssertTrue(usage.contains("Codex") && usage.contains("Claude") && usage.contains("Cursor"))
        XCTAssertTrue(expanded.contains("Demo Reasoner"))
        XCTAssertTrue(compare.contains("Cache write $/1M"))
        let cards = [
            ("usage-card", try ShareCardRenderer.png(snapshots: snapshots, now: now, name: "demo-user")),
            ("model-card", try ModelShareCard.png(catalog: catalog, companies: companies, timeline: timeline, now: now)),
            ("compare-card", try ModelShareCard.png(catalog: catalog, companies: companies, timeline: timeline, comparison: comparison, now: now)),
            ("company-card", try ModelShareCard.png(catalog: catalog, companies: companies, timeline: company, companyCard: true, now: now))
        ]
        for (name, png) in cards {
            try png.write(to: output.appendingPathComponent(name + ".png"))
        }
    }

    private static let snapshots = [
        ProviderSnapshot(title: "Codex", subtitle: "Plus", todayUSD: 2.40, weekUSD: 12.80, monthUSD: 42.60,
            monthTokens: 18_400_000, monthRequests: 520,
            metrics: [Metric("Current window", "24%", progress: 0.24, detail: "reset 15:00"),
                      Metric("Weekly window", "46%", progress: 0.46, detail: "reset Sun 12:00"),
                      Metric("Today", "$2.40", period: .today, detail: "1.2M tokens · 32 requests"),
                      Metric("This week", "$12.80", period: .week, detail: "5.6M tokens · 164 requests"),
                      Metric("This month", "$42.60", period: .month, detail: "18.4M tokens · 520 requests")],
            details: [Metric("Demo Reasoner", "$36.20", detail: "14.1M tokens · 410 req"),
                      Metric("Demo Compact", "$6.40", detail: "4.3M tokens · 110 req")]),
        ProviderSnapshot(title: "Claude", subtitle: "Pro", todayUSD: 1.80, weekUSD: 9.20, monthUSD: 28.40,
            monthTokens: 9_200_000, monthRequests: 240,
            metrics: [Metric("Current window", "72%", progress: 0.72, detail: "reset 16:30"),
                      Metric("Weekly window", "38%", progress: 0.38, detail: "reset Mon 09:00"),
                      Metric("Today", "$1.80", period: .today, detail: "610.0K tokens · 18 requests"),
                      Metric("This week", "$9.20", period: .week, detail: "3.0M tokens · 80 requests"),
                      Metric("This month", "$28.40", period: .month, detail: "9.2M tokens · 240 requests")],
            details: [Metric("Demo Writer", "$28.40", detail: "9.2M tokens · 240 req")],
            notes: ["Estimate from this Mac's logs only; may be incomplete. Not billed spend."]),
        ProviderSnapshot(title: "Cursor", subtitle: "Pro",
            metrics: [Metric("Individual allowance", "62% · $12.40 / $20.00", progress: 0.62, detail: "reset Oct 1 00:00")])
    ]

    // The company names identify UI groups only. Every model, date, price, and score is fictional.
    private static let metadata = #"""
    {
      "openai/demo-reasoner": {"name":"Demo Reasoner","release_date":"2026-09-24","description":"Fictional model for documentation. All dates, prices, and scores in these images are simulated.","knowledge":"2026-06","limit":{"context":1000000,"output":128000},"modalities":{"input":["text","image"],"output":["text"]},"benchmarks":[{"name":"Demo coding score","score":82,"harness":"demo-v1"},{"name":"Demo reasoning score","score":88,"harness":"demo-v1"}]},
      "openai/demo-small": {"name":"Demo Compact","release_date":"2026-09-24","limit":{"context":256000,"output":64000}},
      "anthropic/demo-writer": {"name":"Demo Writer","release_date":"2026-09-23","description":"Fictional model for documentation.","limit":{"context":200000,"output":64000},"modalities":{"input":["text","image"],"output":["text"]},"benchmarks":[{"name":"Demo coding score","score":86,"harness":"demo-v1"},{"name":"Demo reasoning score","score":90,"harness":"demo-v1"}]},
      "google/demo-flash": {"name":"Demo Flash","release_date":"2026-09-21","limit":{"context":1000000,"output":64000},"benchmarks":[{"name":"Demo coding score","score":78,"harness":"demo-v1"},{"name":"Demo reasoning score","score":80,"harness":"demo-v1"}]},
      "openai/demo-previous": {"name":"Demo Previous","release_date":"2026-09-10","limit":{"context":256000,"output":32000}},
      "anthropic/demo-previous": {"name":"Demo Previous","release_date":"2026-09-02"},
      "google/demo-previous": {"name":"Demo Previous","release_date":"2026-08-28"},
      "openai/demo-earlier": {"name":"Demo Earlier","release_date":"2026-08-27","limit":{"context":128000,"output":16000}},
      "openai/demo-first": {"name":"Demo First","release_date":"2026-08-06","limit":{"context":128000,"output":8000}},
      "anthropic/demo-earlier": {"name":"Demo Earlier","release_date":"2026-08-12"},
      "google/demo-earlier": {"name":"Demo Earlier","release_date":"2026-07-30"}
    }
    """#

    private static let prices = #"""
    {
      "openai":{"name":"OpenAI","models":{"demo-reasoner":{"cost":{"input":2,"output":8,"cache_read":0.2,"cache_write":2.5}},"demo-small":{"cost":{"input":0.4,"output":1.6,"cache_read":0.04}},"demo-previous":{"cost":{"input":3,"output":12}}}},
      "anthropic":{"name":"Anthropic","models":{"demo-writer":{"cost":{"input":3,"output":15,"cache_read":0.3,"cache_write":3.75}}}},
      "google":{"name":"Google","models":{"demo-flash":{"cost":{"input":0.5,"output":2,"cache_read":0.05}}}}
    }
    """#
}

/// A minimal PNG presentation of the real renderer's ANSI frame, with a synthetic-data title.
/// Uses fixed terminal cells and the renderer's own width rules; this is not a separate UI.
private enum TerminalScreenshot {
    static func png(_ frame: String, columns: Int, title: String) throws -> Data {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, 14, nil)
        let boldFont = CTFontCreateWithName("Menlo-Bold" as CFString, 14, nil)
        let cell = CGFloat(CTFontGetAdvancesForGlyphs(font, .horizontal, [CTFontGetGlyphWithName(font, "M" as CFString)], nil, 1))
        let lineHeight: CGFloat = 23, margin: CGFloat = 24, titleHeight: CGFloat = 46
        let lines = frame.split(separator: "\n", omittingEmptySubsequences: false)
        let width = ceil(margin * 2 + CGFloat(columns) * cell)
        let height = titleHeight + margin * 2 + CGFloat(lines.count) * lineHeight
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(width * 2), height: Int(height * 2),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        func fill(_ rect: CGRect, _ color: CGColor) { context.setFillColor(color); context.fill(rect) }
        fill(CGRect(x: 0, y: 0, width: width, height: height), rgb(14, 20, 27))
        fill(CGRect(x: 0, y: height - titleHeight, width: width, height: titleHeight), rgb(24, 33, 44))
        for (index, color) in [rgb(255, 95, 87), rgb(254, 188, 46), rgb(40, 200, 64)].enumerated() {
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: margin + CGFloat(index) * 20, y: height - 29, width: 11, height: 11))
        }
        func draw(_ value: String, x: CGFloat, baseline: CGFloat, color: CGColor, bold: Bool = false) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): bold ? boldFont : font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ]))
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
        }
        draw(title, x: margin + 80, baseline: height - 28, color: rgb(157, 173, 191))
        var color = rgb(230, 237, 243), bold = false
        for (row, line) in lines.enumerated() {
            var column = 0
            for (token, width) in TerminalText.tokens(String(line)) {
                if token.hasPrefix("\u{1B}[") {
                    let codes = token.dropFirst(2).dropLast().split(separator: ";").compactMap { Int($0) }
                    var index = 0
                    while index < codes.count {
                        switch codes[index] {
                        case 0: color = rgb(230, 237, 243); bold = false
                        case 1: bold = true
                        case 38 where index + 2 < codes.count && codes[index + 1] == 5:
                            color = indexed(codes[index + 2]); index += 2
                        default: break
                        }
                        index += 1
                    }
                } else {
                    draw(token, x: margin + CGFloat(column) * cell,
                         baseline: height - titleHeight - margin - 15 - CGFloat(row) * lineHeight,
                         color: color, bold: bold)
                    column += width
                }
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> CGColor {
        CGColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    private static func indexed(_ value: Int) -> CGColor {
        if value >= 232 { let gray = 8 + (value - 232) * 10; return rgb(gray, gray, gray) }
        let levels = [0, 95, 135, 175, 215, 255], cube = max(0, value - 16)
        return rgb(levels[min(5, cube / 36)], levels[(cube / 6) % 6], levels[cube % 6])
    }
}
