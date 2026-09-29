import CryptoKit
import Darwin
import Foundation

public enum Distribution {
    public static let repository = "DJean/am-i-cooked"
    public static let repositoryURL = URL(string: "https://github.com/\(repository)")!
}

// Releases have a separate, credential-free transport: provider requests retain
// HTTPClient's stricter same-origin policy, including on redirects.
final class GitHubReleaseRedirectDelegate: NSObject, URLSessionTaskDelegate {
    static func allows(_ url: URL?) -> Bool {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil, let host = parts.host else { return false }
        return ["api.github.com", "github.com", "release-assets.githubusercontent.com",
                "objects.githubusercontent.com"].contains(host)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard Self.allows(request.url) else { completionHandler(nil); return }
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(request)
    }
}

struct GitHubReleaseClient: Sendable {
    typealias Fetch = @Sendable (URL, Int) async throws -> Data
    typealias Run = @Sendable ([String], Int) -> Data?
    let fetch: Fetch
    let run: Run

    init(fetch: @escaping Fetch = Self.publicData, run: @escaping Run = { arguments, limit in
        // gh manages its own credentials and strips authorization on redirects to
        // asset hosts. Tokens are never extracted into cooked's address space.
        Command.data("gh", arguments, timeout: 90, maxBytes: limit)
    }) {
        self.fetch = fetch
        self.run = run
    }

    private static func publicData(_ url: URL, limit: Int) async throws -> Data {
        guard GitHubReleaseRedirectDelegate.allows(url) else { throw URLError(.badURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: GitHubReleaseRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.setValue("cooked", forHTTPHeaderField: "User-Agent")
        // Downloads go to a temporary file, avoiding unbounded in-memory bodies.
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw HTTPError.status((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        return try Data(contentsOf: temporary)
    }

    func latest() async throws -> (SelfUpdater.Release, authenticated: Bool) {
        let endpoint = "repos/\(Distribution.repository)/releases/latest"
        let bytes: Data
        let authenticated: Bool
        do {
            bytes = try await fetch(URL(string: "https://api.github.com/\(endpoint)")!, 1_048_576)
            authenticated = false
        } catch HTTPError.status(let status) where [401, 403, 404].contains(status) {
            try Task.checkCancellation()
            guard let output = run(["api", "--hostname", "github.com", endpoint], 1_048_576) else { throw HTTPError.status(status) }
            bytes = output
            authenticated = true
        }
        return (try SelfUpdater.Release.decode(bytes), authenticated)
    }

    func asset(_ asset: SelfUpdater.Release.Asset, authenticated: Bool, limit: Int) async throws -> Data {
        let data: Data
        if authenticated {
            try Task.checkCancellation()
            let endpoint = "repos/\(Distribution.repository)/releases/assets/\(asset.id)"
            guard let output = run(["api", "--hostname", "github.com", endpoint,
                                    "--header", "Accept: application/octet-stream"], limit) else { throw URLError(.cannotLoadFromNetwork) }
            data = output
        } else {
            data = try await fetch(asset.browserDownloadURL, limit)
        }
        guard data.count == asset.size, data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
}

public enum SelfUpdater {
    struct Version: Comparable {
        let components: [Int]
        init?(_ value: String) {
            guard value.count <= 64,
                  value.range(of: "\\A(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\z", options: .regularExpression) != nil else { return nil }
            let parts = value.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            components = parts
        }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
    }

    struct Release: Decodable {
        struct Asset: Decodable {
            let id: Int
            let name: String
            let size: Int
            let state: String
            let browserDownloadURL: URL
            enum CodingKeys: String, CodingKey { case id, name, size, state; case browserDownloadURL = "browser_download_url" }
        }
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let publishedAt: String?
        let assets: [Asset]
        var version: String { String(tagName.dropFirst()) }
        enum CodingKeys: String, CodingKey {
            case draft, prerelease, assets
            case tagName = "tag_name", publishedAt = "published_at"
        }
        static func decode(_ data: Data) throws -> Self {
            guard data.count <= 1_048_576,
                  let value = try? JSONDecoder().decode(Self.self, from: data),
                  !value.draft, !value.prerelease, value.publishedAt != nil,
                  value.tagName.hasPrefix("v"), Version(value.version) != nil else { throw Failure.invalidManifest }
            _ = try value.asset("manifest.json", limit: 4096)
            _ = try value.asset("cooked", limit: 67_108_864)
            return value
        }
        func asset(_ name: String, limit: Int) throws -> Asset {
            let matches = assets.filter { $0.name == name }
            guard matches.count == 1, let asset = matches.first, asset.id > 0,
                  asset.state == "uploaded", asset.size > 0, asset.size <= limit,
                  asset.browserDownloadURL.absoluteString == "\(Distribution.repositoryURL)/releases/download/\(tagName)/\(name)" else { throw Failure.invalidManifest }
            return asset
        }
    }

    struct Manifest: Decodable {
        let version: String
        let url: URL
        let sha256: String

        static func decode(_ data: Data, release: Release) throws -> Self {
            guard data.count <= 4096,
                  let value = try? JSONDecoder().decode(Self.self, from: data),
                  value.version == release.version,
                  value.sha256.range(of: "\\A[a-fA-F0-9]{64}\\z", options: .regularExpression) != nil,
                  value.url == (try? release.asset("cooked", limit: 67_108_864).browserDownloadURL) else { throw Failure.invalidManifest }
            return value
        }
    }

    private enum Failure: Error { case invalidManifest, checksum, executable, changed }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Installs only newer stable releases. The running process uses the old code
    /// until its next launch. Failures leave the installed executable untouched.
    public static func run(
        executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
        currentVersion: String = Build.version
    ) async -> String? {
        await run(executable: executable, currentVersion: currentVersion, client: GitHubReleaseClient())
    }

    static func run(executable: URL, currentVersion: String, client: GitHubReleaseClient) async -> String? {
        guard let currentVersion = Version(currentVersion) else { return nil }
        let manager = FileManager.default
        let path = executable.standardizedFileURL.path
        let directory = executable.deletingLastPathComponent()
        guard path.hasSuffix("/.local/bin/cooked"),
              let attrs = try? manager.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              manager.isWritableFile(atPath: directory.path) else { return nil }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return nil }
        // Confirm the file opened for locking is still the file at this path.
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (attrs[.systemFileNumber] as? NSNumber)?.uint64Value == opened.st_ino else { return nil }
        for file in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix(".cooked-update-") {
            guard (try? manager.attributesOfItem(atPath: file.path)[.type]) as? FileAttributeType == .typeRegular else { continue }
            let owner = file.lastPathComponent.dropFirst(".cooked-update-".count).split(separator: "-").first
            if let owner, let pid = Int32(owner), kill(pid, 0) == 0 || errno == EPERM { continue }
            try? manager.removeItem(at: file)
        }
        let temporary = directory.appendingPathComponent(".cooked-update-\(getpid())-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        do {
            try Task.checkCancellation()
            let original = try Data(contentsOf: executable)
            let fingerprint = hash(original)
            guard let installedText = Command.output(path, ["--version"]),
                  let installedVersion = Version(installedText) else { return nil }
            let (release, authenticated) = try await client.latest()
            guard let nextVersion = Version(release.version), nextVersion > currentVersion,
                  nextVersion > installedVersion else { return nil }
            let manifestAsset = try release.asset("manifest.json", limit: 4096)
            let manifest = try Manifest.decode(await client.asset(manifestAsset, authenticated: authenticated, limit: 4096), release: release)
            if fingerprint == manifest.sha256.lowercased() { return nil }
            try Task.checkCancellation()
            let binary = try await client.asset(release.asset("cooked", limit: 67_108_864), authenticated: authenticated, limit: 67_108_864)
            guard hash(binary) == manifest.sha256.lowercased() else { throw Failure.checksum }
            try binary.write(to: temporary, options: .withoutOverwriting)
            guard chmod(temporary.path, 0o755) == 0,
                  Command.output(temporary.path, ["--help"]) == "Usage: cooked",
                  Command.output(temporary.path, ["--version"]) == release.version else { throw Failure.executable }
            try Task.checkCancellation()
            let current = try manager.attributesOfItem(atPath: path)
            guard current[.type] as? FileAttributeType == .typeRegular,
                  (current[.systemFileNumber] as? NSNumber) == (attrs[.systemFileNumber] as? NSNumber),
                  hash(try Data(contentsOf: executable)) == fingerprint else { throw Failure.changed }
            guard rename(temporary.path, path) == 0 else { throw Failure.changed }
            return release.version
        } catch { return nil }
    }
}
