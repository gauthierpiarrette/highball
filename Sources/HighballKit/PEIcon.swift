import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The icon a Windows program carries in its own resources, for the Mac shortcuts (ux-plan item
/// 8: a shortcut used to get the store cover cropped square, which reads as "some picture" in the
/// Dock next to real app icons). Reads the PE resource tree for RT_GROUP_ICON, takes the largest
/// entry (256x256 PNG in anything built this decade, a 32-bit DIB in older programs), and hands
/// back PNG bytes. Anything it does not understand (16-colour icons, packed executables) is nil,
/// and the caller falls back to the cover.
public enum PEIcon {
    /// PNG bytes of the largest icon in `exe`, or nil.
    public static func png(from exe: URL) -> Data? {
        guard let data = try? Data(contentsOf: exe, options: .mappedIfSafe) else { return nil }
        return png(fromPE: data)
    }

    /// The program most likely to be the game in a folder: the largest .exe up to three levels
    /// down whose name does not say installer, crash handler or redistributable.
    public static func bestExecutable(in dir: URL) -> URL? {
        let fm = FileManager.default
        let excluded = ["unins", "setup", "redist", "crash", "report", "vc_redist", "vcredist", "dxsetup", "dotnet", "directx", "easyanticheat", "installscript", "launcher_", "helper"]
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return nil }
        var best: (URL, Int)?
        for case let url as URL in e {
            if e.level > 3 { e.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "exe" else { continue }
            let name = url.lastPathComponent.lowercased()
            if excluded.contains(where: { name.contains($0) }) { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if best == nil || size > best!.1 { best = (url, size) }
        }
        return best?.0
    }

    // MARK: PE resources

    static func png(fromPE d: Data) -> Data? {
        guard d.count > 0x40, d[0] == 0x4D, d[1] == 0x5A else { return nil }
        let pe = Int(u32(d, 0x3C))
        guard pe + 24 < d.count, u32(d, pe) == 0x4550 else { return nil }
        let sections = Int(u16(d, pe + 6)), optSize = Int(u16(d, pe + 20)), opt = pe + 24
        guard opt + 2 <= d.count else { return nil }
        let magic = u16(d, opt)
        let ddOffset = opt + (magic == 0x20B ? 112 : 96)   // data directories, PE32+ or PE32
        guard ddOffset + 8 * 3 <= d.count else { return nil }
        let rsrcRVA = Int(u32(d, ddOffset + 8 * 2)), rsrcSize = Int(u32(d, ddOffset + 8 * 2 + 4))
        guard rsrcRVA > 0, rsrcSize > 0 else { return nil }
        // Section table: rva -> file offset.
        var secs: [(va: Int, size: Int, raw: Int)] = []
        let table = opt + optSize
        for i in 0..<sections {
            let s = table + 40 * i
            guard s + 40 <= d.count else { return nil }
            secs.append((Int(u32(d, s + 12)), Int(u32(d, s + 8)), Int(u32(d, s + 20))))
        }
        func off(_ rva: Int) -> Int? {
            for s in secs where rva >= s.va && rva < s.va + max(s.size, 1) { return rva - s.va + s.raw }
            return nil
        }
        guard let root = off(rsrcRVA) else { return nil }
        // Resource directory: Type -> Name/ID -> Language -> data entry.
        func entries(_ dirOff: Int) -> [(id: UInt32, isDir: Bool, next: Int)] {
            guard dirOff + 16 <= d.count else { return [] }
            let named = Int(u16(d, dirOff + 12)), ids = Int(u16(d, dirOff + 14))
            var out: [(UInt32, Bool, Int)] = []
            for i in 0..<(named + ids) {
                let e = dirOff + 16 + 8 * i
                guard e + 8 <= d.count else { break }
                let id = u32(d, e), val = u32(d, e + 4)
                out.append((id, val & 0x8000_0000 != 0, Int(val & 0x7FFF_FFFF)))
            }
            return out
        }
        func firstLeaf(_ dirOff: Int, depth: Int = 0) -> Int? {
            for e in entries(dirOff) {
                if e.isDir { if depth < 2, let leaf = firstLeaf(root + e.next, depth: depth + 1) { return leaf } }
                else { return root + e.next }
            }
            return nil
        }
        func leafData(_ dataEntry: Int) -> Data? {
            guard dataEntry + 16 <= d.count else { return nil }
            let rva = Int(u32(d, dataEntry)), size = Int(u32(d, dataEntry + 4))
            guard let o = off(rva), o + size <= d.count, size > 0 else { return nil }
            return d.subdata(in: o..<(o + size))
        }
        func typeDir(_ type: UInt32) -> Int? { entries(root).first { $0.id == type && $0.isDir }.map { root + $0.next } }
        guard let groups = typeDir(14), let icons = typeDir(3) else { return nil }
        guard let groupLeaf = firstLeaf(groups), let group = leafData(groupLeaf), group.count >= 6 else { return nil }
        // GRPICONDIR: reserved, type, count, then 14-byte entries: w, h, colours, reserved, planes, bits, bytes, id.
        let count = Int(u16(group, 4))
        var bestID: UInt32?, bestScore = -1
        for i in 0..<count {
            let e = 6 + 14 * i
            guard e + 14 <= group.count else { break }
            let w = group[e] == 0 ? 256 : Int(group[e]), bits = Int(u16(group, e + 6)), id = UInt32(u16(group, e + 12))
            let score = w * 1000 + bits
            if score > bestScore { bestScore = score; bestID = id }
        }
        guard let wanted = bestID else { return nil }
        for e in entries(icons) where e.id == wanted && e.isDir {
            guard let leaf = firstLeaf(root + e.next), let icon = leafData(leaf) else { continue }
            if icon.count > 8, icon[0] == 0x89, icon[1] == 0x50, icon[2] == 0x4E, icon[3] == 0x47 { return icon }
            return pngFromDIB(icon)
        }
        return nil
    }

    /// A 32-bit BITMAPINFOHEADER icon (XOR rows bottom-up, BGRA, then the AND mask) as PNG.
    static func pngFromDIB(_ dib: Data) -> Data? {
        guard dib.count >= 40 else { return nil }
        let headerSize = Int(u32(dib, 0)), width = Int(Int32(bitPattern: u32(dib, 4))), height2 = Int(Int32(bitPattern: u32(dib, 8)))
        let bits = Int(u16(dib, 14)), compression = u32(dib, 16)
        guard headerSize == 40, bits == 32, compression == 0, width > 0, height2 > 0 else { return nil }
        let height = height2 / 2, rowBytes = width * 4
        guard 40 + rowBytes * height <= dib.count else { return nil }
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            let src = 40 + (height - 1 - y) * rowBytes
            for x in 0..<width {
                let s = src + x * 4, t = y * rowBytes + x * 4
                let b = dib[s], g = dib[s + 1], r = dib[s + 2], a = dib[s + 3]
                pixels[t] = r; pixels[t + 1] = g; pixels[t + 2] = b; pixels[t + 3] = a
            }
        }
        // Icons without an alpha channel in the XOR data leave every alpha at zero; treat as opaque.
        if !pixels.enumerated().contains(where: { $0.offset % 4 == 3 && $0.element != 0 }) {
            for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 { o + 2 <= d.count ? UInt16(d[o]) | UInt16(d[o + 1]) << 8 : 0 }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        o + 4 <= d.count ? UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24 : 0
    }
}
