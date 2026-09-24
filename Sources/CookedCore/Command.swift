import Foundation
import Darwin

public enum Command {
    public static func output(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
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
            if ProcessInfo.processInfo.systemUptime >= deadline {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return nil
            }
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)); continue }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        // The child can write and exit between the last read and the isRunning check.
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

