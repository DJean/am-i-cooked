import Foundation
import CoreGraphics

public enum PixelAvatar {
    public static func hash(_ name: String) -> UInt64 {
        name.lowercased().utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
    public static func pixels(_ name: String) -> [Int] {
        let h = hash(name)
        var pixels = Array(repeating: 0, count: 144)
        func cells(_ rows: ClosedRange<Int>, _ columns: ClosedRange<Int>, _ value: Int = 1) {
            for r in rows { for c in columns { pixels[r * 12 + c] = value } }
        }
        let antenna = 4 + Int((h >> 8) % 4)
        cells(0...1, antenna...antenna); cells(2...2, 3...8); cells(3...5, 2...9)
        cells(6...6, 3...8); cells(7...7, 5...6); cells(8...9, 2...9)
        cells(10...10, 3...4); cells(10...10, 7...8); cells(11...11, 2...4); cells(11...11, 7...9)
        for (row, cols) in [(h & 1 != 0 ? 4 : 3, [1, 10]), (h & 2 != 0 ? 9 : 8, [1, 10])] {
            for c in cols { pixels[row * 12 + c] = 1 }
        }
        let eyes = [[4, 7], [3, 8], [4, 5, 6, 7]][Int((h >> 2) % 3)]
        for c in eyes { pixels[4 * 12 + c] = 2 }
        let mouth = [[5, 6], [4, 7], [4, 5, 6, 7]][Int((h >> 4) % 3)]
        for c in mouth { pixels[5 * 12 + c] = 0 }
        for k in 0...2 where (h >> (12 + k)) & 1 != 0 { pixels[9 * 12 + 3 + k] = 0; pixels[9 * 12 + 8 - k] = 0 }
        return pixels
    }
}

public enum ShareCardRenderer {
    public static func save(snapshots: [ProviderSnapshot], now: Date = Date(), name: String = "cooked user",
                            directory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) throws -> URL {
        try CardCanvas.save(png(snapshots: snapshots, now: now, name: name), now: now, directory: directory)
    }
    public static func png(snapshots: [ProviderSnapshot], now: Date = Date(), name: String = "cooked user") throws -> Data {
        let providers = snapshots.filter { $0.monthUSD != nil || $0.metrics.contains { $0.period == .month } }
            .enumerated().sorted { $0.element.monthUSD == $1.element.monthUSD ? $0.offset < $1.offset : ($0.element.monthUSD ?? -1) > ($1.element.monthUSD ?? -1) }.map(\.element)
        guard !providers.isEmpty else { throw CardError(message: "No monthly usage to share.") }
        let today = providers.compactMap(\.todayUSD), month = providers.compactMap(\.monthUSD)
        let monthLabel: CGFloat = today.isEmpty ? 184 : 284, heroBottom = monthLabel + 62
        let firstRow = heroBottom + 70, lastRow = firstRow + CGFloat(providers.count - 1) * 27
        let footerRule = lastRow + 24, height = footerRule + 36 + 34
        let card = try CardCanvas(height: height, now: now)
        card.avatar(name, x: 44, y: 72)
        card.text(name, 124, 104, 21, card.white, maxWidth: 190, minimumSize: 14, bold: true)
        card.text("// AGENT USAGE CARD", 124, 126, 9, card.muted, maxWidth: 180)
        func sum(_ counts: [Int]) -> Int { counts.reduce(0) { let n = $0.addingReportingOverflow(max(0, $1)); return n.overflow ? Int.max : n.partialValue } }
        let statistics = [("TOKENS", sum(providers.map(\.monthTokens))), ("REQUESTS", sum(providers.map(\.monthRequests))), ("MODELS", sum(providers.map { $0.details.count }))]
        var baseline: CGFloat = 92
        for (label, value) in statistics where value > 0 {
            card.text(Format.count(value) + " " + label, 436, baseline, 8, card.muted, maxWidth: 116, right: true)
            baseline += 22
        }
        if !today.isEmpty {
            card.text("TODAY", 44, 184, 10, card.muted)
            card.amount(today.reduce(0, +), x: 44, baseline: 226, size: 30, color: card.white)
        }
        card.text("THIS MONTH", 44, monthLabel, 10, card.accent)
        if !month.isEmpty { card.amount(month.reduce(0, +), x: 44, baseline: heroBottom, size: 46, color: card.accent, glow: true) }
        else { card.text("—", 44, heroBottom, 46, card.accent, glow: true) }
        card.rule(firstRow - 44)
        for (i, provider) in providers.enumerated() {
            let value = provider.monthUSD.map(Format.money) ?? provider.metrics.first { $0.period == .month }?.value ?? "—"
            let y = firstRow + CGFloat(i) * 27
            let used = card.text(value, 436, y, 13, card.white, maxWidth: 180, right: true)
            card.text(provider.title.uppercased(), 44, y, 12, card.muted, maxWidth: 372 - used, kern: 1.5)
        }
        return try card.png(note: "includes estimates", footerRule: footerRule, footerSpacing: 36)
    }
}
