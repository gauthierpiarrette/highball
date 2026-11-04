import Foundation

/// Play from outside the app (UX plan §3.9): a `highball://play/...` URL that names something
/// already in the library by a typed id, never a path or an argument list, and carries a
/// per-install token so a web page opening the scheme gets a confirmation instead of a launch.
public enum PlayLink {
    public static let scheme = "highball"

    public enum Target: Equatable, Sendable {
        case steam(appid: Int)
        case epic(appName: String)
        case gog(id: String)
        case pin(bottle: String, id: UUID)
        /// A game Battle.net installed, by Blizzard's product code (highball#417, #432).
        case battlenet(product: String)
        /// A launcher (Steam, Epic, …) by recipe id: `highball://open/launcher/steam`. Opens it,
        /// installing it first if needed (issue #53: Mac icons for launchers too).
        case launcher(id: String)

        /// The library item id this target maps to ("steam:620", "epic:Duck", "pin:Gaming:<uuid>");
        /// a launcher has no library item and maps to "launcher:<id>".
        public var libraryID: String {
            switch self {
            case let .steam(appid): return "steam:\(appid)"
            case let .epic(name): return "epic:\(name)"
            case let .gog(id): return "gog:\(id)"
            case let .pin(bottle, id): return "pin:\(bottle):\(id.uuidString)"
            case let .battlenet(product): return "battlenet:\(product)"
            case let .launcher(id): return "launcher:\(id)"
            }
        }

        /// The target a library id names, the inverse of `libraryID`: what `highball play` takes
        /// (highball#432), so a frontend starts a game by the same id `highball library` lists and
        /// library.json keys everything by. An environment's name may hold a colon, so a program's
        /// id splits at its last one. Anything else is nil.
        public init?(libraryID id: String) {
            guard let colon = id.firstIndex(of: ":") else { return nil }
            let rest = String(id[id.index(after: colon)...])
            guard !rest.isEmpty else { return nil }
            switch id[..<colon] {
            case "steam":
                guard let appid = Int(rest), appid > 0 else { return nil }
                self = .steam(appid: appid)
            case "epic":
                self = .epic(appName: rest)
            case "gog":
                guard rest.allSatisfy(\.isNumber) else { return nil }
                self = .gog(id: rest)
            case "pin":
                guard let last = rest.lastIndex(of: ":") else { return nil }
                let bottle = String(rest[..<last])
                guard !bottle.isEmpty, let uuid = UUID(uuidString: String(rest[rest.index(after: last)...])) else { return nil }
                self = .pin(bottle: bottle, id: uuid)
            case "battlenet":
                guard Self.isProductCode(rest) else { return nil }
                self = .battlenet(product: rest)
            case "launcher":
                guard rest.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else { return nil }
                self = .launcher(id: rest)
            default:
                return nil
            }
        }

        /// Blizzard's product codes are short words of letters, digits and underscores (wow_classic).
        static func isProductCode(_ s: String) -> Bool {
            s.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil
        }
    }

    public struct Request: Equatable, Sendable {
        public let target: Target
        public let token: String?
    }

    /// Parses `highball://play/steam/620?t=<token>`, `highball://play/epic/<name>?t=...`,
    /// `highball://play/gog/<product id>?t=...`,
    /// `highball://play/pin/<bottle>/<uuid>?t=...` and `highball://open/launcher/<id>?t=...`.
    /// Anything else is nil: no other action exists behind the scheme.
    public static func parse(_ url: URL) -> Request? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "t" }?.value
        if url.host?.lowercased() == "open" {
            guard parts.count == 2, parts[0] == "launcher", !parts[1].isEmpty,
                  parts[1].range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else { return nil }
            return Request(target: .launcher(id: parts[1]), token: token)
        }
        guard url.host?.lowercased() == "play" else { return nil }
        switch parts.first {
        case "steam":
            guard parts.count == 2, let appid = Int(parts[1]), appid > 0 else { return nil }
            return Request(target: .steam(appid: appid), token: token)
        case "epic":
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            return Request(target: .epic(appName: parts[1]), token: token)
        case "gog":
            guard parts.count == 2, !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) else { return nil }
            return Request(target: .gog(id: parts[1]), token: token)
        case "pin":
            guard parts.count == 3, !parts[1].isEmpty, let id = UUID(uuidString: parts[2]) else { return nil }
            return Request(target: .pin(bottle: parts[1], id: id), token: token)
        case "battlenet":
            guard parts.count == 2, Target.isProductCode(parts[1]) else { return nil }
            return Request(target: .battlenet(product: parts[1]), token: token)
        default:
            return nil
        }
    }

    public static func url(for target: Target, token: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme; c.host = "play"
        switch target {
        case let .steam(appid): c.path = "/steam/\(appid)"
        case let .epic(name): c.path = "/epic/\(name)"
        case let .gog(id): c.path = "/gog/\(id)"
        case let .pin(bottle, id): c.path = "/pin/\(bottle)/\(id.uuidString)"
        case let .battlenet(product): c.path = "/battlenet/\(product)"
        case let .launcher(id): c.host = "open"; c.path = "/launcher/\(id)"
        }
        c.queryItems = [URLQueryItem(name: "t", value: token)]
        return c.url!
    }

    public static func target(for item: LibraryItem) -> Target? {
        if let appid = item.steamAppID { return .steam(appid: appid) }
        if let name = item.epicAppName { return .epic(appName: name) }
        if let id = item.gogID { return .gog(id: id) }
        if let id = item.pinID, let bottle = item.bottleName { return .pin(bottle: bottle, id: id) }
        if let product = item.battleNetProduct { return .battlenet(product: product) }
        return nil
    }

    /// The per-install token, created on first use in Highball's data folder. Stubs embed it;
    /// a request without it, or with another install's, gets a confirmation.
    public static func token(in paths: HighballPaths) -> String {
        let file = paths.home.appending(path: "launch-token")
        if let t = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try? paths.ensure()
        try? fresh.write(to: file, atomically: true, encoding: .utf8)
        return fresh
    }
}
