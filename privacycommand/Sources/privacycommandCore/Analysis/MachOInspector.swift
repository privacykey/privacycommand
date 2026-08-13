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
        /// Linker-stated minimum OS (LC_BUILD_VERSION.minos or an
        /// LC_VERSION_MIN_* command) -- the binary's own floor, which can
        /// differ from Info.plist's LSMinimumSystemVersion.
        public var minOSVersion: String?
        /// SDK the binary was built against (LC_BUILD_VERSION.sdk).
        public var sdkVersion: String?
        /// Build platform: "macOS", "macCatalyst", "iOS", ... (nil if unknown).
        public var buildPlatform: String?
        /// How many Mach-O arch slices we actually parsed (1 for a thin
        /// binary; >1 means we covered every slice of a fat binary, not just
        /// the first -- load commands can differ between slices).
        public var sliceCount: Int

        public static let empty = LoadCommandsSummary(rpaths: [], dylibs: [],
                                                      hasEncryptedSegment: false,
                                                      isStripped: false,
                                                      minOSVersion: nil, sdkVersion: nil,
                                                      buildPlatform: nil, sliceCount: 0)
    }

    /// Best-effort parse of every arch slice for the load-command details we
    /// care about. Returns `.empty` for unrecognised formats rather than
    /// throwing — this is a soft analysis, not a load-bearing parser.
    public static func loadCommands(of url: URL) -> LoadCommandsSummary {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count >= 32 else { return .empty }
        // Parse EVERY arch slice, not just the first -- a fat binary's second
        // slice can carry dylibs/rpaths/encryption the first slice doesn't, and
        // inspecting only slice 1 lets that linkage hide from analysis.
        let slices = enumerateSlices(in: data)
        guard !slices.isEmpty else { return .empty }

        var rpaths = Set<String>(), dylibs = Set<String>()
        var encrypted = false
        var strippedAll = true
        var minOS: String?, sdk: String?, platform: String?
        var parsed = 0
        for (offset, is64) in slices {
            let s = parseThinLoadCommands(in: data, at: offset, is64: is64)
            guard s.sliceCount > 0 else { continue }
            parsed += 1
            rpaths.formUnion(s.rpaths)
            dylibs.formUnion(s.dylibs)
            encrypted = encrypted || s.hasEncryptedSegment
            strippedAll = strippedAll && s.isStripped
            if minOS == nil { minOS = s.minOSVersion }
            if sdk == nil { sdk = s.sdkVersion }
            if platform == nil { platform = s.buildPlatform }
        }
        guard parsed > 0 else { return .empty }
        return LoadCommandsSummary(
            rpaths: rpaths.sorted(), dylibs: dylibs.sorted(),
            hasEncryptedSegment: encrypted, isStripped: strippedAll,
            minOSVersion: minOS, sdkVersion: sdk, buildPlatform: platform,
            sliceCount: parsed)
    }

    /// Enumerate the (offset, is64) of every Mach-O slice -- one entry for a
    /// thin file, every fat arch for a universal binary.
    private static func enumerateSlices(in data: Data) -> [(Int, Bool)] {
        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        if magic == mh_magic || magic == mh_cigam     { return [(0, false)] }
        if magic == mh_magic_64 || magic == mh_cigam_64 { return [(0, true)] }
        let isFat = magic == fatMagic || magic == fatMagicSwapped
            || magic == fat64Magic || magic == fat64MagicSwapped
        guard isFat, data.count >= 8 else { return [] }
        let swapped = magic == fatMagicSwapped || magic == fat64MagicSwapped
        let is64 = magic == fat64Magic || magic == fat64MagicSwapped
        var nfat = data.withUnsafeBytes {
            $0.baseAddress!.advanced(by: 4).loadUnaligned(as: UInt32.self)
        }
        if swapped { nfat = nfat.byteSwapped }
        guard nfat >= 1, nfat <= 32 else { return [] }   // sanity bound
        let archSize = is64 ? 32 : 20
        var out: [(Int, Bool)] = []
        for i in 0..<Int(nfat) {
            let archStart = 8 + i * archSize
            guard data.count >= archStart + archSize else { break }
            let offset: UInt64
            if is64 {
                var raw: UInt64 = 0
                data.withUnsafeBytes {
                    raw = $0.baseAddress!.advanced(by: archStart + 8).loadUnaligned(as: UInt64.self)
                }
                offset = swapped ? raw.byteSwapped : raw
            } else {
                var raw: UInt32 = 0
                data.withUnsafeBytes {
                    raw = $0.baseAddress!.advanced(by: archStart + 8).loadUnaligned(as: UInt32.self)
                }
                offset = UInt64(swapped ? raw.byteSwapped : raw)
            }
            guard offset + 4 <= UInt64(data.count) else { continue }
            let sliceMagic = data.withUnsafeBytes {
                $0.baseAddress!.advanced(by: Int(offset)).loadUnaligned(as: UInt32.self)
            }
            let sliceIs64 = sliceMagic == mh_magic_64 || sliceMagic == mh_cigam_64
            let isMachO = sliceMagic == mh_magic || sliceMagic == mh_cigam || sliceIs64
            if isMachO { out.append((Int(offset), sliceIs64)) }
        }
        return out
    }

    /// The undefined **external** symbols a Mach-O imports — i.e. the
    /// functions it calls in shared libraries (`_connect`, `_dlopen`,
    /// `_SecItemCopyMatching`, …). These are the *capabilities* the binary
    /// references and are the robust, instant answer to "what is this binary
    /// asking the OS to do?" — far more reliable than parsing a full text
    /// disassembly, and readable even on encrypted App Store binaries (the
    /// `__LINKEDIT` symbol table is not encrypted).
    ///
    /// Parses `LC_SYMTAB` in EVERY arch slice directly — no `nm`/`objdump`
    /// dependency, so it works even without Xcode Command Line Tools. Slices
    /// of a universal binary can import different symbols (and x86_64 slices
    /// spell some libc imports differently, e.g. `_stat$INODE64`), so the
    /// result is the de-duplicated union across all slices: a symbol imported
    /// by only one slice is still reported.
    /// Leading underscores are preserved (Mach-O convention). Returns at most
    /// `limit` symbols. Returns `[]` (never throws) for unparseable inputs.
    public static func importedSymbols(of url: URL, limit: Int = 8000) -> [String] {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count >= 32 else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        for (sliceOffset, is64) in enumerateSlices(in: data) {
            guard out.count < limit else { break }
            for name in parseImportedSymbols(in: data, at: sliceOffset, is64: is64, limit: limit) {
                guard out.count < limit else { break }
                if seen.insert(name).inserted { out.append(name) }
            }
        }
        return out
    }

    public static func architectures(of url: URL) throws -> [String] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= 4 else { return [] }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        // Multi-arch fat binaries
        if magic == fatMagic || magic == fatMagicSwapped || magic == fat64Magic || magic == fat64MagicSwapped {
            return try parseFat(data: data, swapped: (magic == fatMagicSwapped || magic == fat64MagicSwapped),
                                is64: (magic == fat64Magic || magic == fat64MagicSwapped))
        }
        // Thin Mach-O
        if let arch = thinArch(magic: magic) {
            // Thin file — read cputype from offset 4 (32-bit) or 4 (64-bit) — same offset
            let cputype = data.withUnsafeBytes {
                $0.baseAddress!.advanced(by: 4).loadUnaligned(as: Int32.self)
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
            nfat = rawBuffer.baseAddress!.advanced(by: 4).loadUnaligned(as: UInt32.self)
        }
        if swapped { nfat = nfat.byteSwapped }

        var archs: [String] = []
        let archSize = is64 ? 32 : 20
        for i in 0..<Int(nfat) {
            let off = 8 + i * archSize
            guard data.count >= off + archSize else { break }
            var cputype: Int32 = 0
            data.withUnsafeBytes {
                cputype = $0.baseAddress!.advanced(by: off).loadUnaligned(as: Int32.self)
            }
            if swapped { cputype = Int32(bitPattern: UInt32(bitPattern: cputype).byteSwapped) }
            archs.append(archName(cputype: cputype))
        }
        return archs
    }

    // MARK: - Load command parsing

    /// Decode a Mach-O nibble-packed version (X.Y.Z in bits xxxx.yy.zz).
    static func decodeVersion(_ v: UInt32) -> String {
        let x = (v >> 16) & 0xFFFF, y = (v >> 8) & 0xFF, z = v & 0xFF
        return z == 0 ? "\(x).\(y)" : "\(x).\(y).\(z)"
    }

    /// LC_BUILD_VERSION platform id -> name.
    static func platformName(_ p: UInt32) -> String? {
        switch p {
        case 1: return "macOS"
        case 2: return "iOS"
        case 3: return "tvOS"
        case 4: return "watchOS"
        case 5: return "bridgeOS"
        case 6: return "macCatalyst"
        case 7: return "iOS Simulator"
        case 8: return "tvOS Simulator"
        case 9: return "watchOS Simulator"
        case 10: return "DriverKit"
        default: return nil
        }
    }

    private static func parseThinLoadCommands(in data: Data, at sliceOffset: Int, is64: Bool) -> LoadCommandsSummary {
        // mach_header(_64): magic(4) cputype(4) cpusubtype(4) filetype(4)
        //                   ncmds(4) sizeofcmds(4) flags(4) [reserved(4) for 64]
        let headerSize = is64 ? 32 : 28
        guard data.count >= sliceOffset + headerSize else { return .empty }

        let magic = data.withUnsafeBytes {
            $0.baseAddress!.advanced(by: sliceOffset).loadUnaligned(as: UInt32.self)
        }
        let swap = magic == mh_cigam || magic == mh_cigam_64
        func u32(_ off: Int) -> UInt32 {
            let raw = data.withUnsafeBytes {
                $0.baseAddress!.advanced(by: off).loadUnaligned(as: UInt32.self)
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
        let LC_VERSION_MIN_MACOSX: UInt32   = 0x24
        let LC_VERSION_MIN_IPHONEOS: UInt32 = 0x25
        let LC_VERSION_MIN_TVOS: UInt32     = 0x2F
        let LC_VERSION_MIN_WATCHOS: UInt32  = 0x30
        let LC_BUILD_VERSION: UInt32        = 0x32

        var rpaths: [String] = []
        var dylibs: [String] = []
        var hasEncryptedSegment = false
        var hasSymtab = false
        var symStringCount: UInt32 = 0
        var minOSVersion: String?
        var sdkVersion: String?
        var buildPlatform: String?

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
            case LC_BUILD_VERSION:
                // build_version_command: cmd cmdsize platform(4) minos(4) sdk(4) ntools(4)
                if cmdSize >= 24 {
                    buildPlatform = Self.platformName(u32(cursor + 8))
                    minOSVersion = Self.decodeVersion(u32(cursor + 12))
                    let sdk = u32(cursor + 16)
                    if sdk != 0 { sdkVersion = Self.decodeVersion(sdk) }
                }
            case LC_VERSION_MIN_MACOSX, LC_VERSION_MIN_IPHONEOS,
                 LC_VERSION_MIN_TVOS, LC_VERSION_MIN_WATCHOS:
                // version_min_command: cmd cmdsize version(4) sdk(4) -- older form.
                if cmdSize >= 16, minOSVersion == nil {
                    minOSVersion = Self.decodeVersion(u32(cursor + 8))
                    let sdk = u32(cursor + 12)
                    if sdk != 0 { sdkVersion = Self.decodeVersion(sdk) }
                    switch cmd {
                    case LC_VERSION_MIN_MACOSX:   buildPlatform = buildPlatform ?? "macOS"
                    case LC_VERSION_MIN_IPHONEOS: buildPlatform = buildPlatform ?? "iOS"
                    case LC_VERSION_MIN_TVOS:     buildPlatform = buildPlatform ?? "tvOS"
                    default:                      buildPlatform = buildPlatform ?? "watchOS"
                    }
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
            isStripped: isStripped,
            minOSVersion: minOSVersion, sdkVersion: sdkVersion,
            buildPlatform: buildPlatform, sliceCount: 1)
    }

    /// Locate `LC_SYMTAB`, walk the nlist table and collect the names of all
    /// undefined external symbols (the imports). Bounds-checked throughout —
    /// a malformed table yields whatever we parsed before the bad entry, not
    /// a crash.
    private static func parseImportedSymbols(in data: Data, at sliceOffset: Int, is64: Bool, limit: Int) -> [String] {
        let headerSize = is64 ? 32 : 28
        guard data.count >= sliceOffset + headerSize else { return [] }

        let magic = data.withUnsafeBytes {
            $0.baseAddress!.advanced(by: sliceOffset).loadUnaligned(as: UInt32.self)
        }
        let swap = magic == mh_cigam || magic == mh_cigam_64
        func u32(_ off: Int) -> UInt32 {
            guard off >= 0, data.count >= off + 4 else { return 0 }
            let raw = data.withUnsafeBytes {
                $0.baseAddress!.advanced(by: off).loadUnaligned(as: UInt32.self)
            }
            return swap ? raw.byteSwapped : raw
        }

        let LC_SYMTAB: UInt32 = 0x2
        let ncmds = u32(sliceOffset + 16)
        var cursor = sliceOffset + headerSize

        var symoff: UInt32 = 0, nsyms: UInt32 = 0, stroff: UInt32 = 0, strsize: UInt32 = 0
        var found = false
        for _ in 0..<Int(ncmds) {
            guard data.count >= cursor + 8 else { break }
            let cmd = u32(cursor)
            let cmdSize = u32(cursor + 4)
            guard cmdSize >= 8, data.count >= cursor + Int(cmdSize) else { break }
            if cmd == LC_SYMTAB, cmdSize >= 24 {
                symoff  = u32(cursor + 8)
                nsyms   = u32(cursor + 12)
                stroff  = u32(cursor + 16)
                strsize = u32(cursor + 20)
                found = true
                break
            }
            cursor += Int(cmdSize)
        }
        guard found, nsyms > 0 else { return [] }

        // nlist offsets are relative to the slice (the Mach-O image) base.
        let symBase = sliceOffset + Int(symoff)
        let strBase = sliceOffset + Int(stroff)
        let strEnd  = strBase + Int(strsize)
        let nlistSize = is64 ? 16 : 12
        guard symBase >= 0, strBase >= 0,
              strEnd <= data.count,
              data.count >= symBase + Int(nsyms) * nlistSize else {
            // String table or symbol table runs past EOF — bail rather than
            // read garbage (common on truncated / mmapped slices of a fat file).
            // Fall through with whatever bound we *can* safely walk.
            return safeWalk(data: data, swap: swap, is64: is64,
                            symBase: symBase, nsyms: nsyms, nlistSize: nlistSize,
                            strBase: strBase, strEnd: min(strEnd, data.count), limit: limit)
        }
        return safeWalk(data: data, swap: swap, is64: is64,
                        symBase: symBase, nsyms: nsyms, nlistSize: nlistSize,
                        strBase: strBase, strEnd: strEnd, limit: limit)
    }

    private static func safeWalk(data: Data, swap: Bool, is64: Bool,
                                 symBase: Int, nsyms: UInt32, nlistSize: Int,
                                 strBase: Int, strEnd: Int, limit: Int) -> [String] {
        // nlist(_64): n_strx(4) n_type(1) n_sect(1) n_desc(2) n_value(4/8)
        let N_STAB: UInt8 = 0xe0
        let N_TYPE: UInt8 = 0x0e
        let N_EXT:  UInt8 = 0x01
        let N_UNDF: UInt8 = 0x00

        var out: [String] = []
        var seen = Set<String>()
        out.reserveCapacity(min(Int(nsyms), limit))

        data.withUnsafeBytes { rb in
            let base = rb.baseAddress!.assumingMemoryBound(to: UInt8.self)
            func u32at(_ off: Int) -> UInt32 {
                let v = UnsafeRawPointer(base + off).loadUnaligned(as: UInt32.self)
                return swap ? v.byteSwapped : v
            }
            for i in 0..<Int(nsyms) {
                if out.count >= limit { break }
                let entry = symBase + i * nlistSize
                // `entry >= 0` is belt-and-braces: on a 64-bit platform the
                // offsets above can't go negative, but this keeps the pointer
                // arithmetic provably in-bounds regardless of future changes.
                guard entry >= 0, entry + nlistSize <= data.count else { break }
                let nType = base[entry + 4]
                // Skip debug (STAB) symbols entirely.
                if (nType & N_STAB) != 0 { continue }
                // Imports = undefined (no section) AND external.
                guard (nType & N_TYPE) == N_UNDF, (nType & N_EXT) != 0 else { continue }
                let nStrx = Int(u32at(entry))
                let nameStart = strBase + nStrx
                guard nameStart >= strBase, nameStart < strEnd else { continue }
                // Read a NUL-terminated name out of the string table.
                var j = nameStart
                while j < strEnd, base[j] != 0 { j += 1 }
                guard j > nameStart else { continue }
                let bytes = UnsafeBufferPointer(start: base + nameStart, count: j - nameStart)
                if let name = String(bytes: bytes, encoding: .utf8), seen.insert(name).inserted {
                    out.append(name)
                }
            }
        }
        return out
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
