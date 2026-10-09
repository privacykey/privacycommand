import Foundation
import privacycommandCLIKit

/// Live progress for blocking CLI work, drawn in place on stderr: the app
/// rows of a `ProgressBoard` (none for a single job, such as the one-shot
/// audit) and a footer with a braille spinner and the elapsed time. A
/// background queue repaints it ten times a second; callers update rows and
/// the footer from any thread.
///
/// It draws **only when stderr is a TTY**, so `--json` / redirected stdout
/// stays clean and piped or CI runs print nothing; `enabled` tells callers
/// when to fall back to plain progress lines. `log` prints a whole line above
/// the board either way, so a note never lands in the middle of a frame.
final class StatusBoard: @unchecked Sendable {   // every field is guarded by `lock`

    private static let frames: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// True when the board animates (stderr is a terminal).
    let enabled: Bool
    private let ansi: Ansi
    private let queue = DispatchQueue(label: "com.privacykey.privacycommand.statusboard")
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()

    private var rows: [ProgressBoard.Row] = []
    /// Per-row text re-read on every frame — e.g. the bytes downloaded so far.
    private var liveStatus: [String: () -> String?] = [:]
    private var footer = ""
    private var liveFooter: (() -> String?)?
    private var running = false
    private var painted = 0   // lines currently on screen, for the redraw
    private var startTime = Date()

    init(forceEnabled: Bool = false) {
        enabled = forceEnabled || isatty(STDERR_FILENO) != 0
        // Colour follows the NO_COLOR convention; --no-color governs the
        // report on stdout and is applied by the caller through `log`.
        let noColor = ProcessInfo.processInfo.environment["NO_COLOR"]?.isEmpty == false
        ansi = Ansi(enabled: enabled && !noColor)
    }

    // MARK: - Lifecycle

    func start() {
        guard enabled else { return }
        lock.lock(); running = true; startTime = Date(); lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            var i = 0
            while true {
                self.lock.lock()
                guard self.running else { self.lock.unlock(); break }
                self.paint(frame: Self.frames[i % Self.frames.count])
                self.lock.unlock()
                i += 1
                Thread.sleep(forTimeInterval: 0.1)
            }
            self.done.signal()
        }
    }

    /// Stop the animation and erase the board so the report starts on a clean row.
    func stop() {
        guard enabled else { return }
        lock.lock(); let wasRunning = running; running = false; lock.unlock()
        guard wasRunning else { return }
        done.wait()   // let the loop finish its current frame
        lock.lock(); clear(); lock.unlock()
    }

    // MARK: - Content

    /// The line under the rows (or the only line): what's happening overall.
    /// `live`, when given, is re-read on every frame and appended after a dash.
    func setFooter(_ text: String, live: (() -> String?)? = nil) {
        lock.lock(); footer = text; liveFooter = live; lock.unlock()
    }

    func setRows(_ rows: [ProgressBoard.Row]) {
        lock.lock(); self.rows = rows; liveStatus = [:]; lock.unlock()
    }

    /// Change one row. `live`, when given, replaces its status text on every
    /// frame until the next update.
    func update(_ id: String, live: (() -> String?)? = nil,
                _ change: (inout ProgressBoard.Row) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[i])
        liveStatus[id] = live
    }

    /// Print a whole line above the board (or plainly when it isn't
    /// animating) — to stderr for a note, or to stdout for the report's own
    /// first lines.
    func log(_ line: String, toStdout: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        clear()
        if toStdout {
            print(line)
            fflush(stdout)
        } else {
            Self.write(line + "\n")
        }
    }

    // MARK: - Painting (lock held)

    private func paint(frame: Character) {
        let (columns, lines) = Self.terminalSize()
        let composed = rows.map { row -> ProgressBoard.Row in
            guard let live = liveStatus[row.id], let text = live() else { return row }
            var r = row; r.status = text; return r
        }
        var footerText = footer
        if let extra = liveFooter?(), !extra.isEmpty { footerText += " — " + extra }
        let secs = Int(Date().timeIntervalSince(startTime))
        footerText += " · \(secs)s"

        // Leave room for the header above, the prompt below, and a margin.
        let board = ProgressBoard.render(rows: composed, footer: footerText, frame: frame,
                                         width: columns, maxRows: max(0, lines - 4), ansi: ansi)
        // \r to column 0, up to the board's first line, repaint each line
        // cleared to EOL, then clear whatever an earlier, taller frame left.
        var out = "\r"
        if painted > 1 { out += "\u{1B}[\(painted - 1)A" }
        out += board.map { $0 + "\u{1B}[K" }.joined(separator: "\n")
        out += "\u{1B}[J"
        Self.write(out)
        painted = board.count
    }

    private func clear() {
        guard painted > 0 else { return }
        var out = "\r"
        if painted > 1 { out += "\u{1B}[\(painted - 1)A" }
        out += "\u{1B}[J"
        Self.write(out)
        painted = 0
    }

    /// An analyzer step as a row or footer reads: `Checking code signature`
    /// → `checking code signature`.
    static func phaseText(_ phase: String) -> String {
        guard let first = phase.first else { return phase }
        return first.lowercased() + phase.dropFirst()
    }

    private static func terminalSize() -> (columns: Int, lines: Int) {
        var size = winsize()
        guard ioctl(STDERR_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else {
            return (80, 24)
        }
        return (Int(size.ws_col), Int(size.ws_row))
    }

    private static func write(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }
}
