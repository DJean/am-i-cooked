import Foundation
import Testing
@testable import CookedCore

struct InstallerTests {
    private final class Fixture {
        let base: URL
        let tools: URL
        let destination: URL
        let manifest: URL
        let binary: URL
        let requests: URL
        let executed: URL
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let version = "0.12.0"

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            tools = base.appendingPathComponent("tools")
            destination = base.appendingPathComponent("installation")
            manifest = base.appendingPathComponent("manifest.json")
            binary = base.appendingPathComponent("cooked")
            requests = base.appendingPathComponent("requests")
            executed = base.appendingPathComponent("executed")
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            try writeScript("""
            #!/bin/sh
            printf 'executed\\n' >> "$COOKED_TEST_EXECUTED"
            case "$1" in
                --version) echo '\(version)' ;;
                --help) echo 'Usage: cooked' ;;
                *) exit 1 ;;
            esac
            """, to: binary)
            try writeScript(#"""
            #!/bin/sh
            case "$1" in -s) echo "${COOKED_TEST_OS:-Darwin}" ;; -m) echo arm64 ;; *) exit 1 ;; esac
            """#, to: tools.appendingPathComponent("uname"))
            try writeScript("#!/bin/sh\necho '13.0'\n", to: tools.appendingPathComponent("sw_vers"))
            try writeScript(#"""
            #!/bin/sh
            url= output=
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -o) output=$2; shift ;;
                    https://*) url=$1 ;;
                esac
                shift
            done
            printf 'curl %s\n' "$url" >> "$COOKED_TEST_REQUESTS"
            [ "$COOKED_TEST_PRIVATE" = 0 ] || exit 22
            case "$url" in
                https://github.com/DJean/am-i-cooked/releases/latest/download/manifest.json) cp "$COOKED_TEST_MANIFEST" "$output" ;;
                https://github.com/DJean/am-i-cooked/releases/download/v0.12.0/cooked) cp "$COOKED_TEST_BINARY" "$output" ;;
                *) exit 1 ;;
            esac
            """#, to: tools.appendingPathComponent("curl"))
            try writeScript(#"""
            #!/bin/sh
            [ "$1" = release ] && [ "$2" = download ] || exit 1
            shift 2
            pattern= output= tag= repo=
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --repo) repo=$2; shift ;;
                    --pattern) pattern=$2; shift ;;
                    --output) output=$2; shift ;;
                    --clobber) ;;
                    v*) tag=$1 ;;
                    *) exit 1 ;;
                esac
                shift
            done
            [ "$repo" = github.com/DJean/am-i-cooked ] || exit 1
            printf 'gh %s %s\n' "$pattern" "$tag" >> "$COOKED_TEST_REQUESTS"
            case "$pattern" in
                manifest.json) [ -z "$tag" ] && cp "$COOKED_TEST_MANIFEST" "$output" ;;
                cooked) [ "$tag" = v0.12.0 ] && cp "$COOKED_TEST_BINARY" "$output" ;;
                *) exit 1 ;;
            esac
            """#, to: tools.appendingPathComponent("gh"))
            try writeManifest()
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        func writeScript(_ source: String, to url: URL) throws {
            try Data(source.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func writeManifest(fields: [String: Any] = [:]) throws {
            var payload: [String: Any] = [
                "version": version,
                "url": "https://github.com/DJean/am-i-cooked/releases/download/v\(version)/cooked",
                "sha256": SelfUpdater.hash(try Data(contentsOf: binary))
            ]
            payload.merge(fields) { _, new in new }
            try JSONSerialization.data(withJSONObject: payload).write(to: manifest)
        }

        func run(_ script: String = "install", arguments: [String] = [], privateRepository: Bool = false, os: String = "Darwin") throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [repository.appendingPathComponent(script).path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.environment = [
                "PATH": tools.path + ":/usr/bin:/bin",
                "COOKED_INSTALL_DIR": destination.path,
                "TMPDIR": base.path,
                "COOKED_TEST_MANIFEST": manifest.path,
                "COOKED_TEST_BINARY": binary.path,
                "COOKED_TEST_REQUESTS": requests.path,
                "COOKED_TEST_EXECUTED": executed.path,
                "COOKED_TEST_PRIVATE": privateRepository ? "1" : "0",
                "COOKED_TEST_OS": os
            ]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        var installed: URL { destination.appendingPathComponent("cooked") }
        var requestLines: [String] {
            ((try? String(contentsOf: requests, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
    }

    @Test(arguments: [false, true])
    func installsVerifiedRelease(privateRepository: Bool) throws {
        let fixture = try Fixture()
        #expect(try fixture.run(privateRepository: privateRepository) == 0)
        #expect(try Data(contentsOf: fixture.installed) == Data(contentsOf: fixture.binary))
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.installed.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o755)
        #expect(fixture.requestLines.count == (privateRepository ? 3 : 2))
        if privateRepository {
            #expect(fixture.requestLines.last == "gh cooked v0.12.0")
        }
    }

    @Test func rejectsMalformedManifestBeforeDownloadingOrExecutingBinary() throws {
        let cases: [[String: Any]] = [
            ["version": "0.12.0\nunexpected"], ["version": "00.12.0"], ["version": "0.13.0"],
            ["url": "https://example.com/cooked"],
            ["url": "https://github.com/DJean/am-i-cooked/releases/download/v0.12.0/cooked\n"],
            ["sha256": String(repeating: "a", count: 64) + "\n"],
            ["sha256": ["fake": "value"]], ["sha256": "short"]
        ]
        for fields in cases {
            let fixture = try Fixture()
            try fixture.writeManifest(fields: fields)
            #expect(try fixture.run() != 0)
            #expect(fixture.requestLines.count == 1)
            #expect(!FileManager.default.fileExists(atPath: fixture.executed.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.installed.path))
        }
    }

    @Test func checksumFailurePreservesExistingInstallWithoutExecutingDownload() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(at: fixture.installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = Data("existing install".utf8)
        try previous.write(to: fixture.installed)
        try fixture.writeManifest(fields: ["sha256": String(repeating: "0", count: 64)])
        #expect(try fixture.run() != 0)
        #expect(try Data(contentsOf: fixture.installed) == previous)
        #expect(!FileManager.default.fileExists(atPath: fixture.executed.path))
    }

    @Test func versionMismatchPreservesExistingInstall() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(at: fixture.installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = Data("existing install".utf8)
        try previous.write(to: fixture.installed)
        try fixture.writeScript("#!/bin/sh\necho '0.11.0'\n", to: fixture.binary)
        try fixture.writeManifest()
        #expect(try fixture.run() != 0)
        #expect(try Data(contentsOf: fixture.installed) == previous)
    }

    @Test func rejectsUnsupportedPlatformsAndArgumentsWithoutNetwork() throws {
        let fixture = try Fixture()
        #expect(try fixture.run(os: "Linux") != 0)
        #expect(try fixture.run(arguments: ["https://example.com/manifest.json\nunexpected"]) == 2)
        #expect(try fixture.run("release", arguments: ["0.12.0\nunexpected"]) == 2)
        #expect(fixture.requestLines.isEmpty)
    }
}
