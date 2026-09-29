import Foundation
import Testing
@testable import CookedCore

private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; entries.append(value) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    var count: Int { values.count }
}

struct DistributionTests {
    private func binary(_ version: String = "1.2.3", help: String = "Usage: cooked") -> Data {
        Data("#!/bin/sh\ncase \"$1\" in --version) echo '\(version)' ;; --help) echo '\(help)' ;; esac\n".utf8)
    }

    private func manifest(version: String = "1.2.3", hash: String = String(repeating: "a", count: 64), url: String? = nil) -> Data {
        try! JSONSerialization.data(withJSONObject: ["version": version,
            "url": url ?? "https://github.com/\(Distribution.repository)/releases/download/v\(version)/cooked", "sha256": hash])
    }

    private func release(version: String = "1.2.3", manifestSize: Int = 200, binarySize: Int = 200,
                         draft: Bool = false, prerelease: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: ["tag_name": "v\(version)", "draft": draft, "prerelease": prerelease,
            "published_at": "2026-09-01T00:00:00Z", "assets": [
                ["id": 1, "name": "manifest.json", "state": "uploaded", "size": manifestSize,
                 "browser_download_url": "https://github.com/\(Distribution.repository)/releases/download/v\(version)/manifest.json"],
                ["id": 2, "name": "cooked", "state": "uploaded", "size": binarySize,
                 "browser_download_url": "https://github.com/\(Distribution.repository)/releases/download/v\(version)/cooked"]]])
    }

    @Test func releaseAndManifestArePinnedToRepositoryAndStableVersion() throws {
        let release = try SelfUpdater.Release.decode(release())
        let valid = "https://github.com/\(Distribution.repository)/releases/download/v1.2.3/cooked"
        #expect(try SelfUpdater.Manifest.decode(manifest(url: valid), release: release).url.absoluteString == valid)
        for url in [valid + "?x=1", valid + "#x", valid + "/", valid.replacingOccurrences(of: "1.2.3", with: "01.2.3"),
                    valid.replacingOccurrences(of: "https:", with: "http:"),
                    valid.replacingOccurrences(of: "github.com", with: "github.com.evil.invalid"),
                    valid.replacingOccurrences(of: "github.com", with: "user@github.com"),
                    valid.replacingOccurrences(of: "github.com", with: "github.com:443"),
                    valid.replacingOccurrences(of: "1.2.3", with: "%31.2.3"),
                    valid.replacingOccurrences(of: "1.2.3", with: "latest"),
                    valid.replacingOccurrences(of: Distribution.repository, with: "example/other")] {
            #expect(throws: (any Error).self) { try SelfUpdater.Manifest.decode(manifest(url: url), release: release) }
        }
        for payload in [manifest(version: "1.2.4", url: valid), manifest(hash: "bad"),
                        manifest(hash: String(repeating: "a", count: 64) + "\n"), Data(repeating: 32, count: 4097)] {
            #expect(throws: (any Error).self) { try SelfUpdater.Manifest.decode(payload, release: release) }
        }
        for payload in [self.release(draft: true), self.release(prerelease: true), self.release(version: "1.2.3-beta"),
                        self.release(manifestSize: 4097), self.release(binarySize: 0)] {
            #expect(throws: (any Error).self) { try SelfUpdater.Release.decode(payload) }
        }
        var fields = try #require(JSONSerialization.jsonObject(with: self.release()) as? [String: Any])
        fields["assets"] = (fields["assets"] as! [[String: Any]]) + [(fields["assets"] as! [[String: Any]])[0]]
        #expect(throws: (any Error).self) { try SelfUpdater.Release.decode(JSONSerialization.data(withJSONObject: fields)) }
    }

    @Test func versionsAndDownloadRedirectsAreStrict() throws {
        #expect(try #require(SelfUpdater.Version("0.12.0")) > #require(SelfUpdater.Version("0.9.9")))
        for value in ["01.2.3", "1.2", "1.2.3\n", "1.2.3-beta", "-1.2.3", "999999999999999999999999.0.0"] {
            #expect(SelfUpdater.Version(value) == nil)
        }
        for host in ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"] {
            #expect(GitHubReleaseRedirectDelegate.allows(URL(string: "https://\(host)/asset?signature=fixture")))
        }
        for value in ["http://github.com/asset", "https://github.com:443/asset", "https://user@github.com/asset",
                      "https://github.com.evil.invalid/asset", "https://example.invalid/asset", "https://github.com/asset#fragment"] {
            #expect(!GitHubReleaseRedirectDelegate.allows(URL(string: value)))
        }
    }

    private func executable(version: String = "1.0.0") throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = base.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cooked")
        try binary(version).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    private func clean(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    }

    @Test(arguments: ["success", "checksum", "help", "version", "changed", "symlink", "download"])
    func updateIsAtomic(mode: String) async throws {
        let file = try executable()
        defer { clean(file) }
        let original = try Data(contentsOf: file)
        let replacement = binary(mode == "version" ? "1.2.2" : "1.2.3", help: mode == "help" ? "invalid" : "Usage: cooked")
        let digest = mode == "checksum" ? String(repeating: "0", count: 64) : SelfUpdater.hash(replacement)
        let payload = manifest(hash: digest)
        let metadata = release(manifestSize: payload.count, binarySize: replacement.count)
        let changed = Data("modified concurrently".utf8)
        let client = GitHubReleaseClient(fetch: { url, _ in
            if url.lastPathComponent == "latest" { return metadata }
            if url.lastPathComponent == "manifest.json" { return payload }
            if mode == "download" { throw URLError(.timedOut) }
            if mode == "changed" { try changed.write(to: file) }
            if mode == "symlink" {
                let other = file.deletingLastPathComponent().appendingPathComponent("other")
                try changed.write(to: other)
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
            }
            return replacement
        }, run: { _, _ in Issue.record("Public releases must not invoke gh"); return nil })
        let updated = await SelfUpdater.run(executable: file, currentVersion: "1.0.0", client: client)
        #expect(updated == (mode == "success" ? "1.2.3" : nil))
        #expect(try Data(contentsOf: file) == (mode == "success" ? replacement : ["changed", "symlink"].contains(mode) ? changed : original))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(!remaining.contains { $0.hasPrefix(".cooked-update-") })
    }

    @Test(arguments: ["1.2.3", "2.0.0"])
    func neverDowngradesRunningOrNewerInstalledVersion(version: String) async throws {
        for installed in [false, true] {
            let file = try executable(version: installed ? version : "1.0.0")
            defer { clean(file) }
            let metadata = release()
            let requests = Requests()
            let client = GitHubReleaseClient(fetch: { url, _ in
                requests.append(url.absoluteString)
                #expect(url.lastPathComponent == "latest")
                return metadata
            }, run: { _, _ in Issue.record("No gh fallback expected"); return nil })
            let updated = await SelfUpdater.run(executable: file, currentVersion: installed ? "1.0.0" : version, client: client)
            #expect(updated == nil)
            #expect(requests.count == 1)
        }
    }

    @Test func privateRepositoryUsesExistingGhAuthenticationWithoutTokenExtraction() async throws {
        let file = try executable()
        defer { clean(file) }
        let replacement = binary()
        let payload = manifest(hash: SelfUpdater.hash(replacement))
        let metadata = release(manifestSize: payload.count, binarySize: replacement.count)
        let commands = Requests(), requests = Requests()
        let client = GitHubReleaseClient(fetch: { url, _ in
            requests.append(url.absoluteString)
            throw HTTPError.status(404)
        }, run: { arguments, _ in
            commands.append(arguments.joined(separator: " "))
            #expect(arguments.prefix(3) == ["api", "--hostname", "github.com"])
            if arguments[3].hasSuffix("/latest") { return metadata }
            #expect(arguments.suffix(2) == ["--header", "Accept: application/octet-stream"])
            return arguments[3].hasSuffix("/1") ? payload : replacement
        })
        #expect(await SelfUpdater.run(executable: file, currentVersion: "1.0.0", client: client) == "1.2.3")
        #expect(requests.count == 1)
        #expect(commands.count == 3)
        #expect(commands.values.allSatisfy { !$0.contains("auth token") && $0.contains("repos/\(Distribution.repository)/releases/") })
        #expect(try Data(contentsOf: file) == replacement)
    }

    @Test func symlinksAndNonstandardInstallationsDoNotFetch() async throws {
        let file = try executable()
        defer { clean(file) }
        let other = file.deletingLastPathComponent().appendingPathComponent("other")
        try FileManager.default.moveItem(at: file, to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        let client = GitHubReleaseClient(fetch: { _, _ in Issue.record("Unexpected network request"); throw URLError(.badURL) },
                                        run: { _, _ in Issue.record("Unexpected command"); return nil })
        #expect(await SelfUpdater.run(executable: file, currentVersion: "1.0.0", client: client) == nil)
        #expect(await SelfUpdater.run(executable: other, currentVersion: "1.0.0", client: client) == nil)
    }

    @Test func simultaneousUpdatersDoNotRaceAndStaleFilesAreCleaned() async throws {
        let file = try executable()
        defer { clean(file) }
        let stale = file.deletingLastPathComponent().appendingPathComponent(".cooked-update-old")
        try Data().write(to: stale)
        let directory = file.deletingLastPathComponent().appendingPathComponent(".cooked-update-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let active = file.deletingLastPathComponent().appendingPathComponent(".cooked-update-\(ProcessInfo.processInfo.processIdentifier)-active")
        try Data().write(to: active)
        let metadata = release(version: "1.0.0")
        let requests = Requests()
        let started = AsyncStream<Void>.makeStream(), finish = AsyncStream<Void>.makeStream()
        let client = GitHubReleaseClient(fetch: { url, _ in
            requests.append(url.absoluteString)
            started.continuation.yield(())
            for await _ in finish.stream { break }
            return metadata
        }, run: { _, _ in nil })
        let first = Task { await SelfUpdater.run(executable: file, currentVersion: "1.0.0", client: client) }
        for await _ in started.stream { break }
        #expect(await SelfUpdater.run(executable: file, currentVersion: "1.0.0", client: client) == nil)
        finish.continuation.yield(())
        #expect(await first.value == nil)
        #expect(requests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: active.path))
    }

    @Test func commandPreservesBinaryBytesAndBoundsMemory() {
        #expect(Command.data("/usr/bin/printf", ["\\000\\377 \\n"]) == Data([0, 255, 32, 10]))
        #expect(Command.data("/usr/bin/printf", ["12345"], maxBytes: 4) == nil)
        #expect(Command.data("/usr/bin/printf", ["12345"], maxBytes: 5) == Data("12345".utf8))
    }
}
