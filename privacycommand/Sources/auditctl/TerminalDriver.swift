import Foundation
import Darwin
import privacycommandCore
import auditctlKit

// MARK: - Signal-safe terminal restore

// A signal handler can't capture context, so the bits it needs to put the
// terminal back live at file scope. Set once when raw mode is enabled.
private var gSavedTermios = termios()
private var gTermiosSaved = false
private var gResized: sig_atomic_t = 0
private let gLeaveBytes = Array("\u{1B}[?7h\u{1B}[?25h\u{1B}[?1049l".utf8)

private func restoreTerminalFromSignal() {
    if gTermiosSaved { tcsetattr(STDIN_FILENO, TCSAFLUSH, &gSavedTermios) }
    gLeaveBytes.withUnsafeBytes { _ = write(STDOUT_FILENO, $0.baseAddress, $0.count) }
}

private func onFatalSignal(_ sig: Int32) {
    restoreTerminalFromSignal()
    _exit(128 + sig)
}

private func onWinch(_ sig: Int32) { gResized = 1 }

/// Drives the interactive browser: raw-mode terminal setup, a non-blocking
/// poll loop, background analysis dispatch, and safe teardown. All the *logic*
/// (state, rendering, input decoding, key handling) lives in `auditctlKit`;
/// this type is just the imperative shell that talks to the OS.
final class TerminalDriver {

    private var model: AppBrowserModel
    private let ansi = Ansi(enabled: true)   // the TUI owns the terminal → colour on
    private var running = true
    private var lastBodyHeight = 10

    /// Thread-safe hand-off from the analysis worker back to the main loop.
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, AuditState)] = []
        func push(_ path: String, _ state: AuditState) {
            lock.lock(); items.append((path, state)); lock.unlock()
        }
        func drain() -> [(String, AuditState)] {
            lock.lock(); defer { items.removeAll(); lock.unlock() }
            return items
        }
    }
    private let inbox = Inbox()
    private let analysisQueue = DispatchQueue(label: "com.privacykey.auditctl.tui.analysis")

    init(model: AppBrowserModel) { self.model = model }

    // MARK: - Run loop

    func run() {
        setupTerminal()
        defer { teardownTerminal() }

        kickAnalysisIfNeeded()
        var dirty = true

        while running {
            let completed = inbox.drain()
            if !completed.isEmpty {
                for (path, state) in completed { model.setState(state, forPath: path) }
                dirty = true
            }
            if gResized != 0 { gResized = 0; dirty = true }

            let (w, h) = terminalSize()
            lastBodyHeight = TUIRenderer.bodyHeight(forHeight: h)
            model.updateScroll(viewportHeight: lastBodyHeight)

            if dirty {
                writeString(TUIRenderer.frame(model: model, width: w, height: h, ansi: ansi))
                dirty = false
            }

            if let events = pollInput(timeoutMs: 150) {
                for ev in events { handle(ev); dirty = true }
            }
        }
    }

    private func handle(_ ev: InputEvent) {
        let pageStep = max(1, lastBodyHeight - 1)
        switch BrowserReducer.apply(ev, to: &model, pageStep: pageStep) {
        case .quit:            running = false
        case .analyzeSelected: kickAnalysisIfNeeded()
        case .none:            break
        }
    }

    // MARK: - Analysis dispatch

    private func kickAnalysisIfNeeded() {
        guard let app = model.selectedApp, case .notStarted = model.state(of: app) else { return }
        model.markAnalyzing(path: app.path)
        let (path, url, name) = (app.path, app.url, app.name)
        let inbox = self.inbox
        analysisQueue.async {
            let state: AuditState
            do {
                let report = try StaticAnalyzer().analyze(bundleAt: url)
                let summary = NoteworthySummary.summarize(report)
                state = .done(AuditSnapshot(report: report, summary: summary, fallbackName: name))
            } catch {
                state = .failed(error.localizedDescription)
            }
            inbox.push(path, state)
        }
    }

    // MARK: - Terminal I/O

    private func terminalSize() -> (w: Int, h: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (80, 24)
    }

    private func pollInput(timeoutMs: Int32) -> [InputEvent]? {
        var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&fds, 1, timeoutMs)
        guard ready > 0, (fds.revents & Int16(POLLIN)) != 0 else { return nil }

        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0 ..< n])
                if n < chunk.count { break }   // drained
            } else {
                break                          // EAGAIN or EOF
            }
        }
        return buffer.isEmpty ? nil : InputDecoder.decode(buffer)
    }

    private func writeString(_ s: String) {
        let bytes = Array(s.utf8)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = write(STDOUT_FILENO, base.advanced(by: off), raw.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    // MARK: - Setup / teardown

    private func setupTerminal() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        gSavedTermios = raw
        gTermiosSaved = true
        cfmakeraw(&raw)                       // no echo, no canon, no signals, no OPOST
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

        let flags = fcntl(STDIN_FILENO, F_GETFL)
        _ = fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK)

        // alt screen · hide cursor · disable line-wrap · clear
        writeString("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l\u{1B}[2J")

        signal(SIGINT, onFatalSignal)
        signal(SIGTERM, onFatalSignal)
        signal(SIGWINCH, onWinch)
    }

    private func teardownTerminal() {
        writeString("\u{1B}[?7h\u{1B}[?25h\u{1B}[?1049l")
        if gTermiosSaved { tcsetattr(STDIN_FILENO, TCSAFLUSH, &gSavedTermios) }
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        _ = fcntl(STDIN_FILENO, F_SETFL, flags & ~O_NONBLOCK)
    }
}
