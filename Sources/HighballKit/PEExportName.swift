import Foundation

/// The name a PE (a Windows DLL) gives itself in its export directory. Wine identifies a builtin
/// module by this name on some builds (CrossOver's Wine 11) and by the file name on others
/// (Wine 10), so a second copy of a builtin DLL laid out under another file name still collides
/// with the first unless this internal name changes too (D3DMetal's d3d12.dll behind the
/// timestamp shim: with the internal name untouched, the copy came back as the shim itself and
/// no DirectX 12 device was ever created, 2026-09-08).
public enum PEExportName {
    public enum Failure: Error, Equatable { case notPE, noExports, nameTooLong(max: Int) }

    /// The export directory's name string, or nil when the file is not a PE with exports.
    public static func read(_ d: Data) -> String? {
        guard let o = nameOffset(in: d) else { return nil }
        var end = o
        while end < d.count, d[end] != 0 { end += 1 }
        return String(data: d[o..<end], encoding: .ascii)
    }

    /// The same PE with its export name replaced in place. The new name must fit in the old one's
    /// bytes (the string is padded with zeros): nothing else in the file moves, so the file stays
    /// byte-for-byte the same DLL otherwise.
    public static func patched(_ d: Data, to name: String) throws -> Data {
        guard let o = nameOffset(in: d) else { throw isPE(d) ? Failure.noExports : Failure.notPE }
        var end = o
        while end < d.count, d[end] != 0 { end += 1 }
        let room = end - o
        let bytes = Array(name.utf8)
        guard bytes.count <= room else { throw Failure.nameTooLong(max: room) }
        var out = d
        out.replaceSubrange(o..<end, with: bytes + [UInt8](repeating: 0, count: room - bytes.count))
        return out
    }

    // MARK: PE walking (PE32 and PE32+)

    private static func isPE(_ d: Data) -> Bool {
        guard d.count > 0x40, d[0] == 0x4D, d[1] == 0x5A else { return false }
        let pe = Int(u32(d, 0x3c))
        return pe + 4 <= d.count && d[pe] == 0x50 && d[pe + 1] == 0x45 && d[pe + 2] == 0 && d[pe + 3] == 0
    }

    /// File offset of the export directory's name string.
    static func nameOffset(in d: Data) -> Int? {
        guard isPE(d) else { return nil }
        let pe = Int(u32(d, 0x3c))
        let sections = Int(u16(d, pe + 6)), optSize = Int(u16(d, pe + 20)), opt = pe + 24
        guard optSize >= 96, opt + optSize <= d.count else { return nil }
        let magic = u16(d, opt)
        let ddOffset = opt + (magic == 0x20b ? 112 : 96)         // data directories: PE32+ vs PE32
        guard ddOffset + 8 <= d.count else { return nil }
        let exportRVA = Int(u32(d, ddOffset)), exportSize = Int(u32(d, ddOffset + 4))
        guard exportRVA > 0, exportSize > 0 else { return nil }
        var secs: [(va: Int, size: Int, raw: Int)] = []
        for i in 0..<sections {
            let s = opt + optSize + 40 * i
            guard s + 40 <= d.count else { return nil }
            secs.append((va: Int(u32(d, s + 12)), size: max(Int(u32(d, s + 8)), Int(u32(d, s + 16))), raw: Int(u32(d, s + 20))))
        }
        func off(_ rva: Int) -> Int? {
            for s in secs where rva >= s.va && rva < s.va + max(s.size, 1) { return rva - s.va + s.raw }
            return nil
        }
        guard let dir = off(exportRVA), dir + 40 <= d.count, let name = off(Int(u32(d, dir + 12))), name < d.count else { return nil }
        return name
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 { o + 2 <= d.count ? UInt16(d[o]) | UInt16(d[o + 1]) << 8 : 0 }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        o + 4 <= d.count ? UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24 : 0
    }
}
