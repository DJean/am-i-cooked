import Foundation
import AppKit
import CoreGraphics

/// Network data stays in memory. Rasterization uses the system SVG decoder and a fixed monochrome mask.
public actor LabMarks {
    private let http: HTTPClient
    private var values: [String: Data] = [:]
    private var pending: [String: Task<Data?, Never>] = [:]
    public init(http: HTTPClient = HTTPClient()) { self.http = http }
    public func prefetch(_ companies: [ModelCompany]) async {
        await withTaskGroup(of: Void.self) { group in
            for company in companies { group.addTask { _ = await self.data(for: company.id) } }
        }
    }
    public func data(for company: String) async -> Data? {
        guard company.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else { return nil }
        if let data = values[company] { return data }
        if let task = pending[company] { return await task.value }
        let http = http
        let task = Task { () -> Data? in
            guard let data = try? await http.data(for: URLRequest(url: URL(string: "https://models.dev/logos/\(company).svg")!, timeoutInterval: 5)),
                  Self.mask(data) != nil else { return nil }
            return data
        }
        pending[company] = task
        let data = await task.value
        pending[company] = nil
        if let data { values[company] = data }
        return data
    }
    static func mask(_ data: Data) -> CGImage? {
        guard data.count <= 1_000_000, let svg = String(data: data, encoding: .utf8),
              svg.range(of: #"<svg\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
              svg.range(of: #"<!DOCTYPE|<!ENTITY|<(?:image|script|foreignObject)\b|\b(?:href|src)\s*=|url\s*\(\s*+(?!["']?#)"#,
                        options: [.regularExpression, .caseInsensitive]) == nil,
              let image = NSImage(data: Data(svg.replacingOccurrences(of: "currentColor", with: "#000000").utf8)) else { return nil }
        let size = image.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: 160 * 160 * 4)
        let drew = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 160, height: 160, bitsPerComponent: 8, bytesPerRow: 640,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            let aspect = size.width / size.height
            let w = aspect > 1 ? 160 : 160 * aspect, h = aspect > 1 ? 160 / aspect : 160
            // Draw the vector directly at 4× its 40pt destination, regardless of its intrinsic size.
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: CGRect(x: (160 - w) / 2, y: (160 - h) / 2, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        var mask = [UInt8](repeating: 255, count: 80 * 80)
        for y in 0..<80 { for x in 0..<80 {
            var alpha = 0
            for dy in 0..<2 { for dx in 0..<2 { alpha += Int(pixels[((y * 2 + dy) * 160 + x * 2 + dx) * 4 + 3]) } }
            mask[y * 80 + x] = UInt8(255 - (alpha + 2) / 4)
        } }
        guard let provider = CGDataProvider(data: Data(mask) as CFData) else { return nil }
        return CGImage(maskWidth: 80, height: 80, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 80, provider: provider, decode: nil, shouldInterpolate: true)
    }
}
