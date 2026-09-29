import Foundation
import Darwin

public enum Command {
    public static func output(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        guard let data = data(executable, arguments, timeout: timeout),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    // Keep downloaded bytes intact; text output intentionally trims whitespace.
    public static func data(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5,
                            maxBytes: Int = 16_777_216) -> Data? {
        guard maxBytes > 0 else { return nil }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable.hasPrefix("/") ? executable : "/usr/bin/env")
        process.arguments = executable.hasPrefix("/") ? arguments : [executable] + arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        do { try process.run() } catch { return nil }
        try? pipe.fileHandleForWriting.close()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + (timeout.isFinite ? max(0, timeout) : 5)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while process.isRunning {
            if ProcessInfo.processInfo.systemUptime >= deadline || Task<Never, Never>.isCancelled {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return nil
            }
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard count <= maxBytes - data.count else {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    return nil
                }
                data.append(contentsOf: buffer.prefix(count)); continue
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        // The child can write and exit between the last read and the isRunning check.
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            guard count <= maxBytes - data.count else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        return process.terminationStatus == 0 ? data : nil
    }
}
