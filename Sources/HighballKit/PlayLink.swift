import Foundation

/// Play from outside the app (UX plan §3.9): a `highball://play/...` URL that names something
/// already in the library by a typed id, never a path or an argument list, and carries a
/// per-install token so a web page opening the scheme gets a confirmation instead of a launch.
public enum PlayLink {
    public static let scheme = "highball"

    public enum Target: Equatable, Sendable {
        case steam(appid: Int)
        case epic(appName: String)
        case pin(bottle: String, id: UUID)

        /// The library item id this target maps to ("steam:620", "epic:Duck", "pin:Gaming:<uuid>").
        public var libraryID: String {
            switch self {
            case let .steam(appid): return "steam:\(appid)"
            case let .epic(name): return "epic:\(name)"
            case let .pin(bottle, id): return "pin:\(bottle):\(id.uuidString)"
            }
        }
    }

    public struct Request: Equatable, Sendable {
        public let target: Target
        public let token: String?
    }

    /// Parses `highball://play/steam/620?t=<token>`, `highball://play/epic/<name>?t=...`,
    /// `highball://play/pin/<bottle>/<uuid>?t=...`. Anything else is nil: no other action
    /// exists behind the scheme.
    public static func parse(_ url: URL) -> Request? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "play" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "t" }?.value
        switch parts.first {
        case "steam":
            guard parts.count == 2, let appid = Int(parts[1]), appid > 0 else { return nil }
            return Request(target: .steam(appid: appid), token: token)
        case "epic":
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            return Request(target: .epic(appName: parts[1]), token: token)
        case "pin":
            guard parts.count == 3, !parts[1].isEmpty, let id = UUID(uuidString: parts[2]) else { return nil }
            return Request(target: .pin(bottle: parts[1], id: id), token: token)
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
        case let .pin(bottle, id): c.path = "/pin/\(bottle)/\(id.uuidString)"
        }
        c.queryItems = [URLQueryItem(name: "t", value: token)]
        return c.url!
    }

    public static func target(for item: LibraryItem) -> Target? {
        if let appid = item.steamAppID { return .steam(appid: appid) }
        if let name = item.epicAppName { return .epic(appName: name) }
        if let id = item.pinID, let bottle = item.bottleName { return .pin(bottle: bottle, id: id) }
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
