import Foundation

/// A game the signed-in Steam account owns, installed or not.
public struct OwnedSteamGame: Sendable, Hashable {
    public let appid: Int
    public let name: String
    /// The client's own copies of the artwork in librarycache, when it has them.
    public var localCapsule: URL? = nil
    public var localHeader: URL? = nil

    public init(appid: Int, name: String, localCapsule: URL? = nil, localHeader: URL? = nil) {
        self.appid = appid; self.name = name; self.localCapsule = localCapsule; self.localHeader = localHeader
    }

    /// Local art first: newer apps keep theirs at hashed store paths, so the fixed CDN name
    /// 404s (BALL x PIT, 2062430, checked 2026-09-25) while the client already has the file.
    public var capsuleImage: URL { localCapsule ?? URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(appid)/library_600x900.jpg")! }
    public var headerImage: URL { localHeader ?? URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(appid)/header.jpg")! }
}

/// The account's library, read from what the environment's own Windows Steam client keeps on
/// disk: no network, no credentials, no Web API key (highball#199).
///
/// - `appcache/librarycache/<appid>/` holds each library app's artwork. The client writes one
///   folder per app once it has loaded the library, so the folder names are the owned appids
///   (games, DLC, tools and soundtracks alike).
/// - `appcache/appinfo.vdf` is Steam's binary app database; its `common.type` keeps the games.
///
/// Nothing is there before the first sign-in, which reads as an empty library, not an error.
public enum SteamOwnedLibrary {
    public static func games(in bottle: Bottle) -> [OwnedSteamGame] {
        guard let root = SteamLibrary.steamRoot(of: bottle) else { return [] }
        return games(steamRoot: root)
    }

    /// Cheap change check for a running client: the library fills in after sign-in, and
    /// appinfo.vdf is rewritten as Steam learns about apps. Folder count plus the file's date.
    public static func signature(steamRoot: URL) -> String {
        let fm = FileManager.default
        let count = (try? fm.contentsOfDirectory(atPath: steamRoot.appending(path: "appcache/librarycache").path))?.count ?? 0
        let date = (try? fm.attributesOfItem(atPath: steamRoot.appending(path: "appcache/appinfo.vdf").path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        return "\(count)|\(date)"
    }

    static func games(steamRoot: URL) -> [OwnedSteamGame] {
        let cache = steamRoot.appending(path: "appcache/librarycache")
        let owned = Set(((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).compactMap(Int.init))
        guard !owned.isEmpty,
              let apps = try? SteamAppInfo.read(steamRoot.appending(path: "appcache/appinfo.vdf"), only: owned) else { return [] }
        return owned.compactMap { appid in
            guard let app = apps[appid], app.type?.lowercased() == "game", let name = app.name else { return nil }
            let art = artwork(in: cache.appending(path: String(appid)))
            return OwnedSteamGame(appid: appid, name: name, localCapsule: art["library_600x900.jpg"],
                                  localHeader: art["library_header.jpg"] ?? art["header.jpg"])
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension SteamOwnedLibrary {
    /// Artwork files in one app's librarycache folder, by name. The client keeps them either at
    /// the top or one level down in a folder named for the asset's hash.
    static func artwork(in folder: URL) -> [String: URL] {
        let fm = FileManager.default
        var found: [String: URL] = [:]
        for entry in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                for file in (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [] where found[file.lastPathComponent] == nil {
                    found[file.lastPathComponent] = file
                }
            } else {
                found[entry.lastPathComponent] = entry   // top level wins over a hashed copy
            }
        }
        return found
    }
}

/// Reader for Steam's binary app database, `appcache/appinfo.vdf` (formats 28 and 29). Only the
/// fields the library needs are kept.
///
/// Layout: magic, universe, (v29) the offset of a key-string table at the end of the file, then
/// per app: appid, size, info state, last updated, PICS token, text SHA-1, change number,
/// binary SHA-1, and a binary KeyValues tree whose root is `appinfo`. Type bytes: 0x00 object,
/// 0x01 string, 0x02 int32, 0x03 float, 0x07 uint64, 0x0A int64, 0x08 end of object. In v29
/// keys are int32 indexes into the string table; in v28 they're inline C strings.
public enum SteamAppInfo {
    public struct App: Sendable, Equatable {
        public var name: String?
        public var type: String?
        public var oslist: String?
    }

    public struct ParseError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { "appinfo.vdf: \(message)" }
    }

    static let magic28: UInt32 = 0x0756_4428
    static let magic29: UInt32 = 0x0756_4429

    public static func read(_ url: URL, only wanted: Set<Int>? = nil) throws -> [Int: App] {
        try parse(Data(contentsOf: url, options: .mappedIfSafe), only: wanted)
    }

    static func parse(_ data: Data, only wanted: Set<Int>? = nil) throws -> [Int: App] {
        var r = Reader(bytes: [UInt8](data))
        let magic = try r.u32()
        guard magic == magic28 || magic == magic29 else { throw ParseError(message: String(format: "unknown magic %08x", magic)) }
        _ = try r.u32()   // universe
        var strings: [String]?
        if magic == magic29 {
            var t = Reader(bytes: r.bytes, offset: Int(try r.i64()))
            strings = try (0..<Int(try t.u32())).map { _ in try t.cString() }
        }
        var apps: [Int: App] = [:]
        while true {
            let appid = Int(try r.u32())
            if appid == 0 { break }
            let size = Int(try r.u32())
            let end = r.offset + size
            defer { r.offset = end }
            if let wanted, !wanted.contains(appid) { continue }
            r.offset += 4 + 4 + 8 + 20 + 4 + 20
            let root = try r.object(strings)
            let common = (root["appinfo"]?.object ?? root)["common"]?.object
            apps[appid] = App(name: common?["name"]?.string, type: common?["type"]?.string, oslist: common?["oslist"]?.string)
        }
        return apps
    }

    enum Node {
        case string(String)
        case object([String: Node])
        var string: String? { if case let .string(s) = self { return s }; return nil }
        var object: [String: Node]? { if case let .object(o) = self { return o }; return nil }
    }

    struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard offset + n <= bytes.count else { throw ParseError(message: "truncated at \(offset)") }
            defer { offset += n }
            return bytes[offset..<offset + n]
        }
        mutating func u8() throws -> UInt8 { try take(1).first! }
        mutating func u32() throws -> UInt32 { try take(4).reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        mutating func u64() throws -> UInt64 { try take(8).reversed().reduce(0) { $0 << 8 | UInt64($1) } }
        mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
        mutating func cString() throws -> String {
            let start = offset
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            guard offset < bytes.count else { throw ParseError(message: "unterminated string at \(start)") }
            defer { offset += 1 }
            return String(decoding: bytes[start..<offset], as: UTF8.self)
        }
        mutating func key(_ strings: [String]?) throws -> String {
            guard let strings else { return try cString() }
            let i = Int(try u32())
            guard i < strings.count else { throw ParseError(message: "key index \(i) out of range") }
            return strings[i]
        }
        /// Keys are case-insensitive in Valve's reader; stored lowercased here, so look up lowercase.
        mutating func object(_ strings: [String]?) throws -> [String: Node] {
            var out: [String: Node] = [:]
            while true {
                let type = try u8()
                if type == 0x08 { return out }
                let name = try key(strings).lowercased()
                switch type {
                case 0x00: out[name] = .object(try object(strings))
                case 0x01: out[name] = .string(try cString())
                case 0x02, 0x04, 0x06: out[name] = .string(String(Int32(bitPattern: try u32())))
                case 0x03: out[name] = .string(String(Float(bitPattern: try u32())))
                case 0x07: out[name] = .string(String(try u64()))
                case 0x0A: out[name] = .string(String(try i64()))
                default: throw ParseError(message: "unknown value type \(type) at \(offset - 1)")
                }
            }
        }
    }
}
