import Foundation
import Darwin

/// Wine's on-disk form of an NTFS reparse point, and how to make it usable.
///
/// When a Windows installer creates a directory junction or symbolic link, this Wine
/// (10+, CrossOver 26) leaves an empty directory named after the link plus a trailing `?`,
/// with the raw REPARSE_DATA_BUFFER in the `user.WINEREPARSE` extended attribute. Nothing on
/// the host follows that, and Wine itself did not resolve it either: the EA app's installer
/// makes one for `EA Desktop\EA Desktop`, and the client behind it was "not there" both to
/// Highball and to programs inside the bottle. A real host symlink is followed by both, so this
/// turns such stubs into symlinks, after installs and on demand when a path is missing.
public enum WineReparsePoint {
    public static let attribute = "user.WINEREPARSE"
    /// IO_REPARSE_TAG_SYMLINK and IO_REPARSE_TAG_MOUNT_POINT (a junction).
    static let symlinkTag: UInt32 = 0xA000_000C
    static let mountPointTag: UInt32 = 0xA000_0003
    /// Stubs whose name is taken by the link are moved aside under this prefix.
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

    /// `EA Desktop?` → `EA Desktop`. A stub without the marker keeps its name.
    public static func linkName(forStub name: String) -> String {
        name.hasSuffix("?") ? String(name.dropLast()) : name
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

    // MARK: Materialising

    /// Turns every reparse stub directly inside `dir` into a host symlink. Returns the links made.
    /// Skips stubs whose target is not there (a link to nothing helps nobody) and names that are
    /// already taken by something other than the stub itself.
    @discardableResult
    public static func materialize(in dir: URL, driveC: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var made: [URL] = []
        for name in names where !name.hasPrefix(asidePrefix) {
            let stub = dir.appending(path: name)
            guard let decoded = read(at: stub),
                  let target = hostTarget(decoded, stubParent: dir, driveC: driveC),
                  fm.fileExists(atPath: target.path) else { continue }
            let linkName = linkName(forStub: name)
            let link = dir.appending(path: linkName)
            if linkName == name {
                // The stub occupies the link's name: move the (empty) stub aside first.
                let aside = dir.appending(path: asidePrefix + name)
                try? fm.removeItem(at: aside)
                guard (try? fm.moveItem(at: stub, to: aside)) != nil else { continue }
            } else if (try? fm.attributesOfItem(atPath: link.path)) != nil {
                continue // something already has that name; lstat semantics, so a dangling link counts too
            }
            let destination = decoded.isRelative
                ? decoded.target.replacingOccurrences(of: "\\", with: "/")
                : relativePath(from: dir, to: target)
            if (try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: destination)) != nil {
                made.append(link)
            }
        }
        return made
    }

    /// Materialises stubs anywhere under `root`, directories only, to a bounded depth: installers
    /// put their links a few levels under Program Files, and game trees below that are huge.
    /// `windows/` at the root is skipped.
    @discardableResult
    public static func materializeTree(under root: URL, driveC: URL, maxDepth: Int = 6) -> [URL] {
        let fm = FileManager.default
        var made: [URL] = []
        func walk(_ dir: URL, depth: Int) {
            made += materialize(in: dir, driveC: driveC)
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
        return made
    }

    /// `url` if it exists, else the same path after materialising the stubs that stood in its way,
    /// or nil when something is still missing. Walks from the bottle's drive_c when the path is
    /// inside it, so a missing pin costs a few directory reads and nothing more.
    public static func resolve(_ url: URL, driveC: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return url }
        let path = url.standardizedFileURL.path
        let base = driveC.standardizedFileURL.path
        var current: URL
        var remaining: ArraySlice<String>
        if path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/") {
            current = driveC
            remaining = String(path.dropFirst(base.count)).split(separator: "/").map(String.init)[...]
        } else {
            current = URL(fileURLWithPath: "/")
            remaining = url.standardizedFileURL.pathComponents.dropFirst()[...]
        }
        for component in remaining {
            let next = current.appending(path: component)
            if !fm.fileExists(atPath: next.path) {
                materialize(in: current, driveC: driveC)
                guard fm.fileExists(atPath: next.path) else { return nil }
            }
            current = next
        }
        return current
    }

    /// A relative symlink destination from `dir` to `target` (`../13.783.0.6296/EA Desktop`),
    /// so the link survives the bottle being moved or renamed.
    static func relativePath(from dir: URL, to target: URL) -> String {
        let from = dir.standardizedFileURL.pathComponents
        let to = target.standardizedFileURL.pathComponents
        var common = 0
        while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
        let ups = Array(repeating: "..", count: from.count - common)
        let rest = Array(to[common...])
        let parts = ups + rest
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}
