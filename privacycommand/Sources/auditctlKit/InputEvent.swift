import Foundation

/// A decoded terminal key event. The raw-mode driver reads bytes from stdin
/// and turns them into these; everything downstream reasons about events, not
/// bytes, so the decoding is a pure function we can unit-test.
public enum InputEvent: Equatable, Sendable {
    case up, down, left, right
    case pageUp, pageDown, home, end
    case enter
    case backspace
    case tab
    case escape
    case ctrlC
    case char(Character)
}

public enum InputDecoder {

    /// Decode a chunk of raw stdin bytes into events. A single `read()` in raw
    /// mode usually delivers one keypress, but pasted text or a fast typist can
    /// pack several — and an arrow key is a 3-byte escape sequence — so we scan
    /// the whole buffer.
    public static func decode(_ bytes: [UInt8]) -> [InputEvent] {
        var events: [InputEvent] = []
        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            switch b {
            case 0x03:                       // Ctrl-C
                events.append(.ctrlC); i += 1
            case 0x09:                       // Tab
                events.append(.tab); i += 1
            case 0x0d:                       // CR (Enter); swallow a trailing LF
                events.append(.enter)
                i += (i + 1 < n && bytes[i + 1] == 0x0a) ? 2 : 1
            case 0x0a:                       // LF (Enter)
                events.append(.enter); i += 1
            case 0x08, 0x7f:                 // Backspace / DEL
                events.append(.backspace); i += 1
            case 0x1b:                       // ESC — maybe an arrow / nav sequence
                let (ev, consumed) = decodeEscape(bytes, i)
                if let ev { events.append(ev) }
                i += consumed
            default:
                if b < 0x20 {
                    i += 1                   // ignore other C0 control bytes
                } else {
                    let (ch, consumed) = decodeUTF8(bytes, i)
                    if let ch { events.append(.char(ch)) }
                    i += max(1, consumed)
                }
            }
        }
        return events
    }

    // MARK: - Escape sequences

    /// `bytes[i] == 0x1b`. Handles the CSI (`ESC [ …`) and SS3 (`ESC O …`)
    /// cursor/nav sequences; a lone ESC (nothing usable after it) is `.escape`.
    private static func decodeEscape(_ b: [UInt8], _ i: Int) -> (InputEvent?, Int) {
        let n = b.count
        guard i + 1 < n, b[i + 1] == 0x5b || b[i + 1] == 0x4f else {
            return (.escape, 1)              // bare ESC
        }
        guard i + 2 < n else { return (.escape, 1) }

        let c = b[i + 2]
        switch c {
        case 0x41: return (.up, 3)
        case 0x42: return (.down, 3)
        case 0x43: return (.right, 3)
        case 0x44: return (.left, 3)
        case 0x48: return (.home, 3)
        case 0x46: return (.end, 3)
        default:
            // Numeric "ESC [ <digits> ~" forms (Page Up/Down, some Home/End).
            guard c >= 0x30, c <= 0x39 else { return (nil, 3) }
            var j = i + 2
            while j < n, b[j] >= 0x30, b[j] <= 0x39 { j += 1 }
            guard j < n, b[j] == 0x7e else { return (nil, j - i) }   // malformed
            let consumed = j - i + 1
            switch c {
            case 0x35: return (.pageUp, consumed)     // 5~
            case 0x36: return (.pageDown, consumed)   // 6~
            case 0x31, 0x37: return (.home, consumed) // 1~ / 7~
            case 0x34, 0x38: return (.end, consumed)  // 4~ / 8~
            default: return (nil, consumed)           // e.g. 3~ (Delete) — ignore
            }
        }
    }

    // MARK: - UTF-8

    /// Decode one UTF-8 scalar starting at `i` into a `Character` so accented
    /// app names ("Café") type into the filter correctly.
    private static func decodeUTF8(_ b: [UInt8], _ i: Int) -> (Character?, Int) {
        let n = b.count
        let lead = b[i]
        let len: Int
        if lead < 0x80 { len = 1 }
        else if lead & 0xE0 == 0xC0 { len = 2 }
        else if lead & 0xF0 == 0xE0 { len = 3 }
        else if lead & 0xF8 == 0xF0 { len = 4 }
        else { return (nil, 1) }
        guard i + len <= n else { return (nil, 1) }
        let slice = Array(b[i ..< i + len])
        if let s = String(bytes: slice, encoding: .utf8), let ch = s.first {
            return (ch, len)
        }
        return (nil, 1)
    }
}
