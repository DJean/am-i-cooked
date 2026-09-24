import Foundation
import Testing
@testable import CookedCore

private actor LogoResponses {
    var requests = 0
    let valid = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="12"><path d="M0 0H24V12H0Z" fill="currentColor"/></svg>"#.utf8)

    func response(_ request: URLRequest) async -> (Data, HTTPURLResponse) {
        requests += 1
        let count = requests
        // Allow callers to join the same in-flight request before it completes.
        for _ in 0..<20 { await Task.yield() }
        let data = count == 1 ? Data("not an SVG".utf8) : valid
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

struct LabMarksTests {
    @Test func sharedRequestsValidateBeforeReturningAndRetryFailures() async throws {
        let responses = LogoResponses()
        let marks = LabMarks(http: HTTPClient { await responses.response($0) })
        let values = await withTaskGroup(of: Data?.self, returning: [Data?].self) { group in
            for _ in 0..<20 { group.addTask { await marks.data(for: "openai") } }
            var values: [Data?] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(values.allSatisfy { $0 == nil || LabMarks.mask($0!) != nil })
        #expect(await marks.data(for: "openai") == responses.valid)
        let count = await responses.requests
        #expect(await marks.data(for: "openai") == responses.valid)
        #expect(await marks.data(for: "../openai") == nil)
        #expect(await responses.requests == count)
    }

    @Test func rasterizesAtFixedSizeAndPreservesAspect() throws {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="240000" height="120000" viewBox="0 0 24 12"><path d="M0 0H24V12H0Z" fill="currentColor"/></svg>"#.utf8)
        let mask = try #require(LabMarks.mask(svg))
        #expect(mask.width == 80 && mask.height == 80)
        let pixels = try #require(mask.dataProvider?.data) as Data
        #expect(pixels[10 * 80 + 40] == 255)
        #expect(pixels[40 * 80 + 40] == 0)
        #expect(pixels[70 * 80 + 40] == 255)
    }

    @Test func rejectsExternalResourcesButAllowsLocalPaint() {
        for element in [#"<use href = "https://example.com/logo.svg"/>"#,
                        #"<rect width="24" height="24" fill="url( https://example.com/paint.svg)"/>"#,
                        #"<foreignObject/>"#] {
            let svg = Data((#"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24">"# + element + "</svg>").utf8)
            #expect(LabMarks.mask(svg) == nil)
        }
        let local = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><defs><linearGradient id="ink"><stop stop-color="black"/></linearGradient></defs><rect width="24" height="24" fill="url( #ink)"/></svg>"#.utf8)
        #expect(LabMarks.mask(local) != nil)
    }
}
