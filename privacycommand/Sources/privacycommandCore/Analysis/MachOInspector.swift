import Foundation

/// Reads architecture slices out of a Mach-O / fat-binary file. Pure-Foundation,
/// no `MachO.framework` linkage required.
///
/// Just enough for the static analyzer to report architectures; we don't try to
/// implement a full disassembler.
public enum MachOInspector {

    /// A subset of the load-command information we extract from each
    /// Mach-O slice. Used by RPathAuditor / AntiAnalysisDetector / etc.
    public struct LoadCommandsSummary: Sendable, Hashable, Codable {
        public var rpaths: [String]
        public var dylibs: [String]
        /// True if any LC_ENCRYPTION_INFO[_64] command has cryptid != 0,
        /// meaning at least one segment is encrypted at rest. Real on
        /// Mac App Store apps; impossible to disassemble until decrypted.
        public var hasEncryptedSegment: Bool
        /// True if the binary appears to have been stripped (no __LINKEDIT
        /// symbol table strings). Heuristic.
        public var isStripped: Bool

        public static let empty = LoadCommandsSummary(rpaths: [], dylibs: [],
                                                      hasEncryptedSegment: false,
                                                      isStripped: false)
    }

    /// Best-effort parse of the first thin slice (or first arch of a fat
    /// binary) for the load-command details we care about. Returns
    /// `.empty` for unrecognised formats rather than throwing — this is a
    /// soft analysis, not a load-bearing parser.
    public static func loadCommands(of url: URL) -> LoadCommandsSummary {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count >= 32 else { return .empty }
        let (sliceOffset, is64) = firstThinSlice(in: data)
        guard let sliceOffset else { return .empty }
        return parseThinLoadCommands(in: data, at: sliceOffset, is64: is64)
    }

    public static func architectures(of url: URL) throws -> [String] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= 4 else { return [] }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        // Multi-arch fat binaries
        if magic == fatMagic || magic == fatMagicSwapped || magic == fat64Magic || magic == fat64MagicSwapped {
            return try parseFat(data: data, swapped: (magic == fatMagicSwapped || magic == fat64MagicSwapped),
                                is64: (magic == fat64Magic || magic == fat64MagicSwapped))
        }
        // Thin Mach-O
        if let arch = thinArch(magic: magic) {
            // Thin file — read cputype from offset 4 (32-bit) or 4 (64-bit) — same offset
            let cputype = data.withUnsafeBytes {
                $0.baseAddress!.advanced(by: 4).load(as: Int32.self)
            }
            return [archName(cputype: arch.cputypeOverride ?? cputype)]
        }
        return []
    }

    // MARK: - Internals

    private static let fatMagic:        UInt32 = 0xCAFEBABE
    private static let fatMagicSwapped: UInt32 = 0xBEBAFECA
    private static let fat64Magic:        UInt32 = 0xCAFEBABF
    private static let fat64MagicSwapped: UInt32 = 0xBFBAFECA

    private static let mh_magic:    UInt32 = 0xFEEDFACE
    private static let mh_cigam:    UInt32 = 0xCEFAEDFE
    private static let mh_magic_64: UInt32 = 0xFEEDFACF
    private static let mh_cigam_64: UInt32 = 0xCFFAEDFE

    private struct ThinArch { let cputypeOverride: Int32? }

    private static func thinArch(magic: UInt32) -> ThinArch? {
        switch magic {
        case mh_magic, mh_magic_64, mh_cigam, mh_cigam_64: return ThinArch(cputypeOverride: nil)
        default: return nil
        }
    }

    private static func parseFat(data: Data, swapped: Bool, is64: Bool) throws -> [String] {
        var nfat: UInt32 = 0
        data.withUnsafeBytes { rawBuffer in
            let p = rawBuffer.baseAddress!.advanced(by: 4).assumingMemoryBound(to: UInt32.self)
            nfat = p.pointee
        }
        if swapped { nfat = nfat.byteSwapped }

        var archs: [String] = []
        let archSize = is64 ? 32 : 20
        for i in 0..<Int(nfat) {
            let off = 8 + i * archSize
            guard data.count >= off + archSize else { break }
            var cputype: Int32 = 0
            data.withUnsafeBytes {
                let p = $0.baseAddress!.advanced(by: off).assumingMemoryBound(to: Int32.self)
                cputype = p.pointee
            }
            if swapped { cputype = Int32(bitPattern: UInt32(bitPattern: cputype).byteSwapped) }
            archs.append(archName(cputype: cputype))
        }
        return archs
    }

    // MARK: - Load command parsing

    /// Locate the start of the first thin Mach-O slice. For a thin binary
    /// the offset is 0; for a fat binary we read the first arch's offset.
    private static func firstThinSlice(in data: Data) -> (Int?, Bool) {
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        if magic == mh_magic || magic == mh_cigam     { return (0, false) }
        if magic == mh_magic_64 || magic == mh_cigam_64 { return (0, true) }
        let isFat = magic == fatMagic || magic == fatMagicSwapped
            || magic == fat64Magic || magic == fat64MagicSwapped
        guard isFat, data.count >= 16 else { return (nil, false) }
        let swapped = magic == fatMagicSwapped || magic == fat64MagicSwapped
        let is64 = magic == fat64Magic || magic == fat64MagicSwapped
        // First arch starts at 8; offset field is at +8 (32-bit) or +8 (64-bit).
        // 32-bit arch struct: cputype(4) cpusubtype(4) offset(4) size(4) align(4)
        // 64-bit arch struct: cputype(4) cpusubtype(4) offset(8) size(8) align(4) reserved(4)
        let offsetField = 8 + 8
        let offset: UInt64
        if is64 {
            var raw: UInt64 = 0
            data.withUnsafeBytes {
                let p = $0.baseAddress!.advanced(by: offsetField).assumingMemoryBound(to: UInt64.self)
                raw = p.pointee
            }
            offset = swapped ? raw.byteSwapped : raw
        } else {
            var raw: UInt32 = 0
            data.withUnsafeBytes {
                let p = $0.baseAddress!.advanced(by: offsetField).assumingMemoryBound(to: UInt32.self)
                raw = p.pointee
            }
            offset = UInt64(swapped ? raw.byteSwapped : raw)
        }
        guard offset < UInt64(data.count) else { return (nil, false) }
        let sliceMagic = data.withUnsafeBytes {
            $0.baseAddress!.advanced(by: Int(offset)).load(as: UInt32.self)
        }
        let sliceIs64 = sliceMagic == mh_magic_64 || sliceMagic == mh_cigam_64
        return (Int(offset), sliceIs64)
    }

    private static func parseThinLoadCommands(in data: Data, at sliceOffset: Int, is64: Bool) -> LoadCommandsSummary {
        // mach_header(_64): magic(4) cputype(4) cpusubtype(4) filetype(4)
        //                   ncmds(4) sizeofcmds(4) flags(4) [reserved(4) for 64]
        let headerSize = is64 ? 32 : 28
        guard data.count >= sliceOffset + headerSize else { return .empty }

        let magic = data.withUnsafeBytes {
            $0.baseAddress!.advanced(by: sliceOffset).load(as: UInt32.self)
        }
        let swap = magic == mh_cigam || magic == mh_cigam_64
        func u32(_ off: Int) -> UInt32 {
            let raw = data.withUnsafeBytes {
                $0.baseAddress!.advanced(by: off).load(as: UInt32.self)
            }
            return swap ? raw.byteSwapped : raw
        }

        let ncmds = u32(sliceOffset + 16)
        var cursor = sliceOffset + headerSize

        // Constants
        let LC_REQ_DYLD: UInt32       = 0x80000000
        let LC_LOAD_DYLIB: UInt32     = 0xC
        let LC_LOAD_WEAK_DYLIB: UInt32 = 0x18 | LC_REQ_DYLD
        let LC_REEXPORT_DYLIB: UInt32 = 0x1f | LC_REQ_DYLD
        let LC_LOAD_UPWARD_DYLIB: UInt32 = 0x23 | LC_REQ_DYLD
        let LC_RPATH: UInt32          = 0x1C | LC_REQ_DYLD
        let LC_ENCRYPTION_INFO: UInt32    = 0x21
        let LC_ENCRYPTION_INFO_64: UInt32 = 0x2C
        let LC_SYMTAB: UInt32         = 0x2

        var rpaths: [String] = []
        var dylibs: [String] = []
        var hasEncryptedSegment = false
        var hasSymtab = false
        var symStringCount: UInt32 = 0

        for _ in 0..<Int(ncmds) {
            guard data.count >= cursor + 8 else { break }
            let cmd = u32(cursor)
            let cmdSize = u32(cursor + 4)
            guard cmdSize >= 8, data.count >= cursor + Int(cmdSize) else { break }

            switch cmd {
            case LC_RPATH:
                // rpath_command: cmd(4) cmdsize(4) path_offset(4) path(...)
                let pathOff = u32(cursor + 8)
                let strStart = cursor + Int(pathOff)
                let strEnd = cursor + Int(cmdSize)
                if strStart >= cursor + 12, strEnd <= data.count {
                    rpaths.append(cString(in: data, from: strStart, until: strEnd))
                }
            case LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB:
                // dylib_command: cmd cmdsize dylib_struct{name_offset(4) timestamp(4) current_ver(4) compat_ver(4)}
                let nameOff = u32(cursor + 8)
                let strStart = cursor + Int(nameOff)
                let strEnd = cursor + Int(cmdSize)
                if strStart >= cursor + 24, strEnd <= data.count {
                    dylibs.append(cString(in: data, from: strStart, until: strEnd))
                }
            case LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64:
                // encryption_info_command: cmd cmdsize cryptoff cryptsize cryptid [pad]
                if cmdSize >= 20 {
                    let cryptid = u32(cursor + 16)
                    if cryptid != 0 { hasEncryptedSegment = true }
                }
            case LC_SYMTAB:
                // symtab_command: cmd cmdsize symoff nsyms stroff strsize
                if cmdSize >= 24 {
                    hasSymtab = true
                    symStringCount = u32(cursor + 20)
                }
            default:
                break
            }
            cursor += Int(cmdSize)
        }

        // Stripped heuristic: if there's a SYMTAB but its string table is
        // small relative to expectations, the binary's been stripped of
        // local symbols. <4 KB of strings on a non-trivial binary is a
        // strong signal.
        let isStripped = hasSymtab && symStringCount < 4096

        return LoadCommandsSummary(
            rpaths: rpaths, dylibs: dylibs,
            hasEncryptedSegment: hasEncryptedSegment,
            isStripped: isStripped)
    }

    private static func cString(in data: Data, from start: Int, until end: Int) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(end - start)
        var i = start
        data.withUnsafeBytes { rb in
            let base = rb.baseAddress!.assumingMemoryBound(to: UInt8.self)
            while i < end {
                let b = base[i]
                if b == 0 { return }  // returns from the closure only
                bytes.append(b)
                i += 1
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private static func archName(cputype: Int32) -> String {
        // Subset of <mach/machine.h>
        let CPU_ARCH_ABI64: Int32 = 0x01000000
        let CPU_ARCH_ABI64_32: Int32 = 0x02000000
        let typeOnly = cputype & ~(CPU_ARCH_ABI64 | CPU_ARCH_ABI64_32)
        switch typeOnly {
        case 7:  return (cputype & CPU_ARCH_ABI64) != 0 ? "x86_64" : "i386"
        case 12: return (cputype & CPU_ARCH_ABI64) != 0 ? "arm64"  : "arm"
        case 18: return "ppc"
        default: return "cputype:\(cputype)"
        }
    }
}
