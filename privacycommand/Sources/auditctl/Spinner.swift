import Foundation

/// A progress spinner for the blocking one-shot audit. The analyzer runs
/// synchronously on the main thread and feeds phase text in via `update`; this
/// animates a braille frame + elapsed seconds on a background queue so a slow
/// app (Chrome can take 30s+) shows steady progress instead of looking hung.
///
/// It writes **only to stderr** and **only when stderr is a TTY**, so
/// `--json` / redirected stdout stays clean and piped/CI runs print nothing.
final class Spinner {

    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private let enabled: Bool
    private let queue = DispatchQueue(label: "com.privacykey.auditctl.spinner")
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var message: String
    private var running = false
    private var startTime = Date()

    init(message: String, forceEnabled: Bool = false) {
        self.message = message
        self.enabled = forceEnabled || isatty(FileHandle.standardError.fileDescriptor) != 0
    }

    func start() {
        guard enabled else { return }
        lock.lock(); running = true; startTime = Date(); lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            var i = 0
            while true {
                self.lock.lock()
                let go = self.running
                let msg = self.message
                let start = self.startTime
                self.lock.unlock()
                if !go { break }
                let secs = Int(Date().timeIntervalSince(start))
                let frame = Self.frames[i % Self.frames.count]
                // \r to column 0, \e[K clears to EOL, then repaint.
                Self.writeStderr("\r\u{1B}[K\(frame) \(msg) (\(secs)s)")
                i += 1
                Thread.sleep(forTimeInterval: 0.1)
            }
            self.done.signal()
        }
    }

    /// Swap the phase label (called from the analyzer's progress callback).
    func update(_ msg: String) {
        guard enabled else { return }
        lock.lock(); message = msg; lock.unlock()
    }

    /// Stop the animation and clear the line so the report starts on a clean row.
    func stop() {
        guard enabled else { return }
        lock.lock(); let wasRunning = running; running = false; lock.unlock()
        if wasRunning { done.wait() }   // let the loop finish its current frame
        Self.writeStderr("\r\u{1B}[K")
    }

    private static func writeStderr(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }
}
