import Foundation
import Testing
@testable import CookedCore

private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) { lock.lock(); defer { lock.unlock() }; urls.append(url) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return urls.count }
}

struct DistributionTests {
    private let root = URL(string: "https://example.com/api/v4/projects/1/packages/generic/cooked")!

    private func manifest(_ url: String, hash: String = String(repeating: "a", count: 64)) -> Data {
        try! JSONSerialization.data(withJSONObject: ["url": url, "sha256": hash])
    }

    @Test func strictManifest() throws {
        let valid = root.absoluteString + "/1.2.3/cooked"
        #expect(try SelfUpdater.Manifest.decode(manifest(valid), root: root).url.absoluteString == valid)
        for url in [valid + "?x=1", valid + "#x", valid + "/", valid.replacingOccurrences(of: "1.2.3", with: "01.2.3"),
                    valid.replacingOccurrences(of: "https:", with: "http:"),
                    valid.replacingOccurrences(of: "example.com", with: "example.com.evil.org"),
                    valid.replacingOccurrences(of: "example.com", with: "user@example.com"),
                    valid.replacingOccurrences(of: "example.com", with: "example.com:443"),
                    valid.replacingOccurrences(of: "1.2.3", with: "%31.2.3"),
                    valid.replacingOccurrences(of: "1.2.3", with: "latest")] {
            #expect(throws: (any Error).self) { try SelfUpdater.Manifest.decode(manifest(url), root: root) }
        }
        #expect(throws: (any Error).self) { try SelfUpdater.Manifest.decode(manifest(valid, hash: "bad"), root: root) }
        #expect(throws: (any Error).self) {
            try SelfUpdater.Manifest.decode(manifest(valid, hash: String(repeating: "a", count: 64) + "\n"), root: root)
        }
        #expect(throws: (any Error).self) { try SelfUpdater.Manifest.decode(Data(repeating: 32, count: 4097), root: root) }
    }

    private func executable() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = base.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cooked")
        try Data("#!/bin/sh\nprintf 'Usage: cooked\\n'\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    @Test func equalHashCleansStaleFilesWithoutDownload() async throws {
        let file = try executable()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let stale = file.deletingLastPathComponent().appendingPathComponent(".cooked-update-old")
        try Data().write(to: stale)
        let directory = file.deletingLastPathComponent().appendingPathComponent(".cooked-update-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let active = file.deletingLastPathComponent().appendingPathComponent(".cooked-update-\(ProcessInfo.processInfo.processIdentifier)-active")
        try Data().write(to: active)
        let bytes = try Data(contentsOf: file)
        let payload = manifest(root.absoluteString + "/1.0.0/cooked", hash: SelfUpdater.hash(bytes))
        let requests = Requests()
        let http = HTTPClient { request in
            requests.append(request.url!)
            return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await SelfUpdater.run(executable: file, root: root, http: http)
        #expect(requests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test(arguments: ["success", "checksum", "help", "changed", "download"])
    func updateIsAtomic(mode: String) async throws {
        let file = try executable()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let original = try Data(contentsOf: file)
        let replacement = Data((mode == "help" ? "#!/bin/sh\necho invalid\n" : "#!/bin/sh\n# new version\necho 'Usage: cooked'\n").utf8)
        let digest = mode == "checksum" ? String(repeating: "0", count: 64) : SelfUpdater.hash(replacement)
        let payload = manifest(root.absoluteString + "/1.0.0/cooked", hash: digest)
        let changed = Data("modified concurrently".utf8)
        let http = HTTPClient { request in
            let isManifest = request.url!.lastPathComponent == "manifest.json"
            if !isManifest && mode == "download" { throw URLError(.timedOut) }
            if !isManifest && mode == "changed" { try changed.write(to: file) }
            return (isManifest ? payload : replacement,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await SelfUpdater.run(executable: file, root: root, http: http)
        #expect(try Data(contentsOf: file) == (mode == "success" ? replacement : mode == "changed" ? changed : original))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(remaining == ["cooked"])
    }

    @Test func rejectsSymlinkAndOtherDirectories() async throws {
        let file = try executable()
        let base = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: base) }
        let other = base.appendingPathComponent("cooked")
        try FileManager.default.moveItem(at: file, to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        let requests = Requests()
        let http = HTTPClient { request in
            requests.append(request.url!); throw URLError(.badURL)
        }
        await SelfUpdater.run(executable: file, root: root, http: http)
        await SelfUpdater.run(executable: other, root: root, http: http)
        #expect(requests.count == 0)
    }

    @Test func simultaneousUpdatersDoNotRace() async throws {
        let file = try executable()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let payload = manifest(root.absoluteString + "/1.0.0/cooked", hash: SelfUpdater.hash(try Data(contentsOf: file)))
        let requests = Requests()
        let started = AsyncStream<Void>.makeStream(), finish = AsyncStream<Void>.makeStream()
        let http = HTTPClient { request in
            requests.append(request.url!)
            if requests.count == 1 {
                started.continuation.yield(())
                for await _ in finish.stream { break }
            }
            return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let first = Task { await SelfUpdater.run(executable: file, root: root, http: http) }
        for await _ in started.stream { break }
        await SelfUpdater.run(executable: file, root: root, http: http)
        finish.continuation.yield(())
        await first.value
        #expect(requests.count == 1)
    }

    @Test func scriptsRejectMultilineArgumentsAndManifestFields() throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temporary) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let payload = temporary.appendingPathComponent("manifest.json"), requests = temporary.appendingPathComponent("requests")
        let curl = temporary.appendingPathComponent("curl")
        try Data(#"""
        #!/bin/sh
        printf 'request\n' >> "$COOKED_TEST_REQUESTS"
        while [ "$#" -gt 0 ]; do
            if [ "$1" = '-o' ]; then cp "$COOKED_TEST_MANIFEST" "$2"; exit; fi
            shift
        done
        exit 1
        """#.utf8).write(to: curl)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
        func run(_ script: String, _ argument: String) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [repository.appendingPathComponent(script).path, argument]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = temporary.path + ":/usr/bin:/bin"
            environment["COOKED_TEST_REQUESTS"] = requests.path
            environment["COOKED_TEST_MANIFEST"] = payload.path
            process.environment = environment
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try run("release", "0.11.0\nunexpected") == 2)
        #expect(try run("install", "https://example.com/cooked/latest/manifest.json\nunexpected") == 2)
        #expect(!manager.fileExists(atPath: requests.path))
        let url = "https://example.com/cooked/1.2.3/cooked", hash = String(repeating: "a", count: 64)
        for fields: [String: Any] in [["url": url + "\n", "sha256": hash], ["url": url, "sha256": hash + "\n"],
                                      ["url": url, "sha256": [hash: "value"]]] {
            try JSONSerialization.data(withJSONObject: fields).write(to: payload)
            #expect(try run("install", "https://example.com/cooked/latest/manifest.json") != 0)
        }
        // Every rejected manifest fetched only metadata, never a candidate executable.
        #expect(try String(contentsOf: requests, encoding: .utf8).split(separator: "\n").count == 3)
    }

}
