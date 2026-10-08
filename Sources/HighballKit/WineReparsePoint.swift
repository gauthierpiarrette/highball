import Foundation
import Darwin

/// Wine's on-disk form of an NTFS reparse point, and how Highball reads through it.
///
/// When a Windows installer creates a directory junction or symbolic link, this Wine
/// (11, CrossOver 26) leaves an empty directory named after the link plus a trailing `?`,
/// with the raw REPARSE_DATA_BUFFER in the `user.WINEREPARSE` extended attribute. Wine follows
/// it itself: on the Wine 11 engines r4 and r21, a program reads and lists through the link,
/// starts a program behind it and removes it (measured 2026-10-08 with `mklink /J` and with
/// the EA app's relative `mklink /D` layout). Nothing on the Mac follows it, so Highball's own
/// checks go through `follow`, which writes nothing.
///
/// Highball used to turn such stubs into Mac symlinks of the same name. Wine then took the
/// symlink for an ordinary folder, and removing the link failed with "Directory is not empty"
/// (error 145): the EA app's repair stopped at "Failed to remove reparse point ... error=145"
/// (highball-db#318). `dematerialize` takes those symlinks away again.
public enum WineReparsePoint {
    public static let attribute = "user.WINEREPARSE"
    /// IO_REPARSE_TAG_SYMLINK and IO_REPARSE_TAG_MOUNT_POINT (a junction).
    static let symlinkTag: UInt32 = 0xA000_000C
    static let mountPointTag: UInt32 = 0xA000_0003
    /// Where an older Highball moved a stub whose name its symlink took.
    static let asidePrefix = ".wine-reparse-"

    public struct Decoded: Equatable, Sendable {
        public var tag: UInt32
        /// The substitute name as Windows wrote it: `13.783.0.6296\EA Desktop` (relative) or `\??\C:\…`.
        public var target: String
        public var isRelative: Bool
    }

    // MARK: Reading

    /// Decodes a REPARSE_DATA_BUFFER for the two tags that name a filesystem target.
    public static func decode(_ data: Data) -> Decoded? {
        guard data.count >= 16 else { return nil }
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
        let tag = u32(0)
        let subOffset = u16(8), subLength = u16(10)
        let pathBuffer: Int
        let relative: Bool
        switch tag {
        case symlinkTag:
            guard data.count >= 20 else { return nil }
            pathBuffer = 20; relative = u32(16) & 1 == 1
        case mountPointTag:
            pathBuffer = 16; relative = false
        default:
            return nil
        }
        let start = pathBuffer + subOffset, end = start + subLength
        guard subLength >= 2, end <= bytes.count,
              let name = String(bytes: bytes[start..<end], encoding: .utf16LittleEndian) else { return nil }
        return Decoded(tag: tag, target: name, isRelative: relative)
    }

    /// The reparse data on an entry, if it carries any (the entry itself, not what it may link to).
    public static func read(at url: URL) -> Decoded? {
        let path = url.path
        let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let got = getxattr(path, attribute, &buffer, size, 0, XATTR_NOFOLLOW)
        guard got > 0 else { return nil }
        return decode(Data(buffer[0..<got]))
    }

    /// Where the target lives on the host: relative names hang off the stub's directory,
    /// absolute ones go through the bottle's drives (C: is drive_c, Z: is the host root).
    public static func hostTarget(_ decoded: Decoded, stubParent: URL, driveC: URL) -> URL? {
        var t = decoded.target
        for prefix in ["\\??\\", "\\\\?\\"] where t.hasPrefix(prefix) { t.removeFirst(prefix.count) }
        let unix = t.replacingOccurrences(of: "\\", with: "/")
        let hasDrive = t.count >= 2 && t.dropFirst().hasPrefix(":")
        if decoded.isRelative || !hasDrive {
            return stubParent.appending(path: unix).standardizedFileURL
        }
        var rest = String(unix.dropFirst(2))
        if rest.hasPrefix("/") { rest.removeFirst() }
        switch t.prefix(1).lowercased() {
        case "c": return driveC.appending(path: rest).standardizedFileURL
        case "z": return URL(fileURLWithPath: "/" + rest)
        default: return nil
        }
    }

    /// The components of `url` below drive_c, or nil when it is not inside. Compared as built
    /// first: `standardizedFileURL` drops a leading /private only from paths that exist, so drive_c
    /// and a path through a link below it (which has no Mac side) can come out with different
    /// prefixes (/tmp against /private/tmp).
    static func componentsBelow(_ url: URL, driveC: URL) -> [String]? {
        for (path, base) in [(url.path, driveC.path), (url.standardizedFileURL.path, driveC.standardizedFileURL.path)] {
            let root = base.hasSuffix("/") ? String(base.dropLast()) : base
            if path == root { return [] }
            if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count)).split(separator: "/").map(String.init) }
        }
        return nil
    }

    // MARK: Following

    /// The Mac path `url` lands on when Wine resolves it, going through the stubs on the way
    /// (a stub named after the component plus `?`, or one standing at the component's own name),
    /// or nil when something along it is missing. Writes nothing. Walks from the bottle's drive_c
    /// when `url` is inside it, so a path costs a few directory reads.
    public static func follow(_ url: URL, driveC: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return url }
        var current: URL
        var remaining: ArraySlice<String>
        if let below = componentsBelow(url, driveC: driveC) {
            current = driveC
            remaining = below[...]
        } else {
            current = URL(fileURLWithPath: "/")
            remaining = url.standardizedFileURL.pathComponents.dropFirst()[...]
        }
        for component in remaining {
            let direct = current.appending(path: component)
            if let decoded = read(at: direct), let target = hostTarget(decoded, stubParent: current, driveC: driveC),
               fm.fileExists(atPath: target.path) {
                current = target
            } else if fm.fileExists(atPath: direct.path) {
                current = direct
            } else if let decoded = read(at: current.appending(path: component + "?")),
                      let target = hostTarget(decoded, stubParent: current, driveC: driveC), fm.fileExists(atPath: target.path) {
                current = target
            } else {
                return nil
            }
        }
        return current
    }

    /// The Windows path Wine knows a Mac path inside the bottle by: drive_c is C:, anything else
    /// goes through Z:, the Mac's root.
    public static func windowsPath(for url: URL, driveC: URL) -> String {
        if let below = componentsBelow(url, driveC: driveC) { return "C:\\" + below.joined(separator: "\\") }
        return "Z:" + url.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\")
    }

    // MARK: Undoing the old symlinks

    /// Removes the Mac symlinks an older Highball made for stubs directly inside `dir`: a symlink
    /// whose target is the target of the stub beside it (`name?`) or of the stub it set aside
    /// (`.wine-reparse-name`, which goes back to its name). Any other symlink is left alone.
    /// Returns the links removed.
    @discardableResult
    public static func dematerialize(in dir: URL, driveC: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var removed: [URL] = []
        for name in names where !name.hasPrefix(asidePrefix) && !name.hasSuffix("?") {
            let link = dir.appending(path: name)
            guard (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil else { continue }
            let landing = link.resolvingSymlinksInPath().standardizedFileURL.path
            func pointsHere(_ stub: URL) -> Bool {
                guard let decoded = read(at: stub), let target = hostTarget(decoded, stubParent: dir, driveC: driveC) else { return false }
                return target.resolvingSymlinksInPath().standardizedFileURL.path == landing
            }
            let marked = dir.appending(path: name + "?")
            let aside = dir.appending(path: asidePrefix + name)
            if pointsHere(marked) {
                guard (try? fm.removeItem(at: link)) != nil else { continue }
            } else if pointsHere(aside) {
                guard (try? fm.removeItem(at: link)) != nil else { continue }
                try? fm.moveItem(at: aside, to: link)
            } else {
                continue
            }
            removed.append(link)
        }
        return removed
    }

    /// `dematerialize` anywhere under `root`, directories only, to a bounded depth: installers put
    /// their links a few levels under Program Files, and game trees below that are huge.
    /// `windows/` at the root is skipped, and symlinked folders are not entered.
    @discardableResult
    public static func dematerializeTree(under root: URL, driveC: URL, maxDepth: Int = 6) -> [URL] {
        let fm = FileManager.default
        var removed: [URL] = []
        func walk(_ dir: URL, depth: Int) {
            removed += dematerialize(in: dir, driveC: driveC)
            guard depth < maxDepth,
                  let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                            options: [.skipsHiddenFiles]) else { return }
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                if depth == 0, entry.lastPathComponent.lowercased() == "windows" { continue }
                walk(entry, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return removed
    }

    /// `dematerialize` in each folder along `url` inside drive_c, which is all a launch needs.
    @discardableResult
    public static func dematerializeAlong(_ url: URL, driveC: URL) -> [URL] {
        guard let below = componentsBelow(url, driveC: driveC), !below.isEmpty else { return [] }
        var current = driveC
        var removed: [URL] = []
        for component in below.dropLast() {
            removed += dematerialize(in: current, driveC: driveC)
            current = current.appending(path: component)
        }
        removed += dematerialize(in: current, driveC: driveC)
        return removed
    }
}
