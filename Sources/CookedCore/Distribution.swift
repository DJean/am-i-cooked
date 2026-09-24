import CryptoKit
import Darwin
import Foundation

// Deployment metadata is compiled in; the CLI has no config or persistent state.
public enum Distribution {
    public static let packageRoot: URL? = nil
}

public enum SelfUpdater {
    struct Manifest: Decodable {
        let url: URL
        let sha256: String

        static func decode(_ data: Data, root: URL) throws -> Self {
            guard data.count <= 4096,
                  let value = try? JSONDecoder().decode(Self.self, from: data),
                  value.sha256.range(of: "\\A[a-fA-F0-9]{64}\\z", options: .regularExpression) != nil,
                  let base = URLComponents(url: root, resolvingAgainstBaseURL: false),
                  let url = URLComponents(url: value.url, resolvingAgainstBaseURL: false),
                  base.scheme == "https", base.host != nil,
                  base.user == nil, base.password == nil, base.port == nil,
                  base.query == nil, base.fragment == nil,
                  url.scheme == "https", url.host == base.host, url.user == nil, url.password == nil,
                  url.port == nil, url.query == nil, url.fragment == nil else { throw Failure.invalidManifest }
            let prefix = root.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
            guard value.url.absoluteString.hasPrefix(prefix),
                  String(value.url.absoluteString.dropFirst(prefix.count)).range(
                    of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)/cooked$",
                    options: .regularExpression) != nil else { throw Failure.invalidManifest }
            return value
        }
    }

    private enum Failure: Error { case invalidManifest, checksum, executable, changed }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func run(
        executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
        root: URL? = Distribution.packageRoot,
        http: HTTPClient = HTTPClient()
    ) async {
        guard let root else { return }
        let manager = FileManager.default
        let path = executable.standardizedFileURL.path
        let directory = executable.deletingLastPathComponent()
        guard path.hasSuffix("/.local/bin/cooked"),
              let attrs = try? manager.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              manager.isWritableFile(atPath: directory.path) else { return }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        for file in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix(".cooked-update-") {
            guard (try? manager.attributesOfItem(atPath: file.path)[.type]) as? FileAttributeType == .typeRegular else { continue }
            // A live updater owns its PID; only remove files whose owner has exited.
            let owner = file.lastPathComponent.dropFirst(".cooked-update-".count).split(separator: "-").first
            if let owner, let pid = Int32(owner), kill(pid, 0) == 0 || errno == EPERM { continue }
            try? manager.removeItem(at: file)
        }
        let temporary = directory.appendingPathComponent(".cooked-update-\(getpid())-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        do {
            let original = try Data(contentsOf: executable)
            let fingerprint = hash(original)
            let request = URLRequest(url: root.appendingPathComponent("latest/manifest.json"), timeoutInterval: 15)
            let manifest = try Manifest.decode(await http.data(for: request), root: root)
            if fingerprint == manifest.sha256.lowercased() { return }
            try Task.checkCancellation()
            let binary = try await http.data(for: URLRequest(url: manifest.url, timeoutInterval: 15))
            guard hash(binary) == manifest.sha256.lowercased() else { throw Failure.checksum }
            try binary.write(to: temporary, options: .withoutOverwriting)
            guard chmod(temporary.path, 0o755) == 0,
                  Command.output(temporary.path, ["--help"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "Usage: cooked" else { throw Failure.executable }
            try Task.checkCancellation()
            let current = try manager.attributesOfItem(atPath: path)
            guard current[.type] as? FileAttributeType == .typeRegular,
                  (current[.systemFileNumber] as? NSNumber) == (attrs[.systemFileNumber] as? NSNumber),
                  hash(try Data(contentsOf: executable)) == fingerprint else { throw Failure.changed }
            guard rename(temporary.path, path) == 0 else { throw Failure.changed }
        } catch { /* A failed update never prevents usage monitoring. */ }
    }
}
