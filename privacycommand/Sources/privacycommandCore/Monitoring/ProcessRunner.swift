import Foundation

/// Wraps `Process` for short-lived synchronous calls (codesign, spctl) and
/// long-running streaming reads (lsof loops, fs_usage).
public enum ProcessRunner {

    public struct SyncResult {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public var success: Bool { exitCode == 0 }
    }

    public static func runSync(launchPath: String, arguments: [String], timeout: TimeInterval = 10) -> SyncResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return SyncResult(exitCode: -1, stdout: "", stderr: "Failed to launch \(launchPath): \(error)")
        }

        let killTime = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < killTime {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()

        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        return SyncResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// Runs `launchPath` with `arguments` and yields stdout lines as an
    /// `AsyncStream<String>` (one line per element). The returned `Cancel`
    /// closure terminates the process.
    public static func streamLines(
        launchPath: String,
        arguments: [String]
    ) -> (stream: AsyncStream<String>, cancel: () -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()    // discard

        let stream = AsyncStream<String>(bufferingPolicy: .bufferingNewest(4096)) { continuation in
            let handle = outPipe.fileHandleForReading
            let buffer = LineBuffer()

            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    continuation.finish()
                    return
                }
                let lines = buffer.append(data)
                for line in lines {
                    continuation.yield(line)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
                if process.isRunning {
                    process.terminate()
                }
            }
        }
        let cancel: () -> Void = {
            outPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }
        return (stream, cancel)
    }
}

/// Helper that buffers raw `Data` chunks into newline-delimited strings.
final class LineBuffer {
    private var pending = Data()
    private let queue = DispatchQueue(label: "privacycommand.LineBuffer")

    /// Appends `data` and returns any complete lines that result.
    func append(_ data: Data) -> [String] {
        queue.sync {
            pending.append(data)
            var out: [String] = []
            while let nl = pending.firstIndex(of: 0x0A) {
                let lineData = pending.prefix(upTo: nl)
                pending.removeSubrange(...nl)
                if let s = String(data: lineData, encoding: .utf8) {
                    out.append(s)
                }
            }
            return out
        }
    }
}
