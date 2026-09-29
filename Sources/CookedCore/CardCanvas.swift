import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO

struct CardError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CardPalette {
    let background: CGColor, border: CGColor, primary: CGColor, accent: CGColor, glow: CGColor
    static let standard = CardPalette(background: rgb(0.02, 0.024, 0.035), border: rgb(0.137, 0.165, 0.192),
        primary: rgb(0.93, 0.95, 0.96), accent: rgb(0.3, 0.92, 0.7), glow: rgb(0.3, 0.92, 0.7, 0.4))
    static let ion = CardPalette(background: rgb(0.012, 0.024, 0.055), border: rgb(0.106, 0.153, 0.251),
        primary: rgb(0.929, 0.953, 1), accent: rgb(0.345, 0.843, 1), glow: rgb(0.478, 0.361, 1, 0.5))
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
}

struct CardCanvas {
    let width: CGFloat, height: CGFloat
    let margin: CGFloat = 44
    let palette: CardPalette
    var white: CGColor { palette.primary }
    let muted = CardPalette.rgb(0.54, 0.57, 0.61), faint = CardPalette.rgb(0.35, 0.39, 0.43)
    var accent: CGColor { palette.accent }
    private let context: CGContext
    private let fontName: String

    init(width: CGFloat = 480, height: CGFloat, now: Date, palette: CardPalette = .standard) throws {
        guard width.isFinite, height.isFinite, width >= 1, height >= 1, ceil(width * 2) * ceil(height * 2) <= 16_000_000 else {
            throw CardError(message: "Too many models to fit one card.")
        }
        guard let context = CGContext(data: nil, width: Int(ceil(width * 2)), height: Int(ceil(height * 2)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CardError(message: "Could not create share card.") }
        self.width = width; self.height = height; self.context = context; self.palette = palette
        fontName = ["SFMono-Regular", "Menlo-Regular", "Monaco"].first {
            CTFontCopyPostScriptName(CTFontCreateWithName($0 as CFString, 12, nil)) as String == $0
        } ?? "Monaco"
        context.scaleBy(x: 2, y: 2)
        rect(0, 0, width, height, palette.background)
        context.setShouldAntialias(false)
        for x in stride(from: CGFloat(13), to: width, by: 26) {
            for y in stride(from: CGFloat(13), to: height, by: 26) { rect(x, y, 2, 2, palette.border.copy(alpha: 0.45)!) }
        }
        context.setShouldAntialias(true)
        text("✻  AM I COOKED?", margin, 46, 13, accent, glow: true, bold: true)
        text(Format.dateText(now, "dd MMM yyyy").uppercased(), width - margin, 46, 10, muted, right: true)
    }
    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: CGColor) {
        context.setFillColor(color); context.fill(CGRect(x: x, y: self.height - y - height, width: width, height: height))
    }
    func rule(_ y: CGFloat) { rect(margin, y, width - margin * 2, 0.5, palette.border) }
    func line(_ text: String, _ size: CGFloat, _ color: CGColor, bold: Bool = false, kern: CGFloat = 0) -> CTLine {
        let base = CTFontCreateWithName(fontName as CFString, size, nil)
        let font = bold ? CTFontCreateCopyWithSymbolicTraits(base, size, nil, .boldTrait, .boldTrait) ?? base : base
        return CTLineCreateWithAttributedString(NSAttributedString(string: TerminalText.clean(text), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): kern
        ]))
    }
    func lineWidth(_ line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }
    @discardableResult
    func text(_ value: String, _ x: CGFloat, _ baseline: CGFloat, _ size: CGFloat, _ color: CGColor,
              maxWidth: CGFloat = 392, minimumSize: CGFloat = 8, right: Bool = false, glow: Bool = false,
              bold: Bool = false, kern: CGFloat = 0) -> CGFloat {
        var size = size, rendered = line(value, size, color, bold: bold, kern: kern)
        while lineWidth(rendered) > maxWidth && size > minimumSize {
            size = max(minimumSize, size - 0.5); rendered = line(value, size, color, bold: bold, kern: kern)
        }
        // Card content is wrapped before drawing; unusually wide values are scaled, never truncated.
        let measured = lineWidth(rendered), scale = measured > maxWidth ? maxWidth / measured : 1
        context.saveGState()
        if glow { context.setShadow(offset: .zero, blur: 6, color: palette.glow) }
        context.translateBy(x: right ? x - measured * scale : x, y: height - baseline)
        context.scaleBy(x: scale, y: scale)
        context.textPosition = .zero
        CTLineDraw(rendered, context); context.restoreGState()
        return measured * scale
    }
    func amount(_ value: Double, x: CGFloat, baseline: CGFloat, size: CGFloat, color: CGColor, glow: Bool = false) {
        let parts = Format.money(value).split(separator: ".", maxSplits: 1).map(String.init)
        let integer = parts[0], fraction = parts.count > 1 ? "." + parts[1] : ""
        var size = size
        while lineWidth(line(integer, size, color, bold: true)) + lineWidth(line(fraction, size * 0.55, color, bold: true)) > width - margin * 2 && size > 14 { size -= 0.5 }
        let used = text(integer, x, baseline, size, color, maxWidth: width - margin * 2, glow: glow, bold: true)
        text(fraction, x + used, baseline, size * 0.55, color, maxWidth: max(1, width - margin - x - used), glow: glow, bold: true)
    }
    func avatar(_ name: String, x: CGFloat, y: CGFloat) {
        let hue = CGFloat(PixelAvatar.hash(name) % 360) / 360
        func hsv(_ hue: CGFloat, _ saturation: CGFloat, _ value: CGFloat) -> CGColor {
            let h = (hue - floor(hue)) * 6, sector = Int(h), fraction = h - floor(h)
            let p = value * (1 - saturation), q = value * (1 - fraction * saturation), t = value * (1 - (1 - fraction) * saturation)
            let rgb: (CGFloat, CGFloat, CGFloat)
            switch sector { case 0: rgb = (value, t, p); case 1: rgb = (q, value, p); case 2: rgb = (p, value, t)
            case 3: rgb = (p, q, value); case 4: rgb = (t, p, value); default: rgb = (value, p, q) }
            return CardPalette.rgb(rgb.0, rgb.1, rgb.2)
        }
        let colors = [hsv(hue, 0.72, 0.34), hsv(hue + 0.47, 0.38, 0.9), hsv(hue + 0.14, 0.7, 1)]
        rect(x, y, 68, 68, palette.border); rect(x + 2, y + 2, 64, 64, colors[0])
        for (i, pixel) in PixelAvatar.pixels(name).enumerated() { rect(x + 10 + CGFloat(i % 12) * 4, y + 10 + CGFloat(i / 12) * 4, 4, 4, colors[pixel]) }
    }
    func logo(_ mask: CGImage, x: CGFloat = 44, y: CGFloat = 94) {
        context.saveGState()
        context.clip(to: CGRect(x: x, y: height - y - 40, width: 40, height: 40), mask: mask)
        context.setFillColor(white); context.fill(CGRect(x: x, y: height - y - 40, width: 40, height: 40))
        context.restoreGState()
    }
    func png(note: String, footerRule: CGFloat? = nil, footerSpacing: CGFloat = 32) throws -> Data {
        let y = footerRule ?? height - 62
        rule(y)
        let credit = Distribution.repositoryURL.absoluteString, creditWidth = lineWidth(line(credit, 10, accent))
        text(note, margin, y + footerSpacing, 9, muted, maxWidth: max(1, width - margin * 2 - creditWidth - 12))
        text(credit, width - margin, y + footerSpacing, 10, accent, right: true)
        for y in stride(from: CGFloat(0), to: height, by: 3) { rect(0, y, width, 1, CGColor(gray: 0, alpha: 0.06)) }
        guard let image = context.makeImage() else { throw CardError(message: "Could not create share card.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw CardError(message: "Could not encode share card.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CardError(message: "Could not encode share card.") }
        return data as Data
    }
    static func save(_ data: Data, prefix: String = "cooked", now: Date, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = prefix + "-" + Format.dateText(now, "yyyy-MM-dd-HHmmss")
        var number = 1
        while true {
            let url = directory.appendingPathComponent(stem + (number == 1 ? "" : "-\(number)") + ".png")
            do { try data.write(to: url, options: .withoutOverwriting); return url }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { number += 1 }
        }
    }
}
