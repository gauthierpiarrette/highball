import Foundation

/// A Steam account that has signed in to an environment's Steam, known by its display name only:
/// the profile name friends see. Steam also keeps each account's sign-in name beside it
/// (loginusers.vdf's AccountName), half of what signs in, so it is never read.
public struct SteamAccount: Sendable, Hashable {
    /// The 64-bit Steam ID, which install records (LastOwner) and loginusers.vdf name accounts
    /// by; the registry and userdata use the 32-bit account ID, its offset from steamIDBase.
    public let id: UInt64
    public let displayName: String
    /// When the account last signed in to this Steam.
    public let lastSignIn: Date?

    public init(id: UInt64, displayName: String, lastSignIn: Date? = nil) {
        self.id = id; self.displayName = displayName; self.lastSignIn = lastSignIn
    }
}

/// Which Steam accounts use an environment's Steam, which one is signed in, and which one
/// installed a game, so a game page can say "Installed by" and warn when Steam is signed in to
/// another account, which may not have the game (a household sharing one Mac).
/// Read from files already on the Mac, never sent anywhere. Ownership itself is not knowable:
/// Steam's per-account license list (userdata/<id>/config/licensecache) is encrypted.
public enum SteamAccounts {
    /// The first 64-bit Steam ID; an account ID (the registry's, userdata's) is the offset from it.
    static let steamIDBase: UInt64 = 76561197960265728

    /// The accounts in Steam's config/loginusers.vdf, newest sign-in first.
    public static func known(steamRoot: URL) -> [SteamAccount] {
        guard let text = try? String(contentsOf: steamRoot.appending(path: "config/loginusers.vdf"), encoding: .utf8)
        else { return [] }
        return parse(loginUsers: text)
    }

    static func parse(loginUsers text: String) -> [SteamAccount] {
        let users = TextKeyValues.parse(text).child("users")?.children ?? []
        let accounts = users.compactMap { key, block -> SteamAccount? in
            // Only these two values are taken; the sign-in name beside them never leaves the file.
            guard let id = UInt64(key), let name = block.child("personaname")?.string, !name.isEmpty else { return nil }
            let signedIn = block.child("timestamp")?.string.flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
            return SteamAccount(id: id, displayName: name, lastSignIn: signedIn)
        }
        return accounts.sorted { ($0.lastSignIn ?? .distantPast) > ($1.lastSignIn ?? .distantPast) }
    }

    /// The account Steam is signed in to while it runs: the registry's ActiveUser (an account
    /// ID, 0 once Steam has quit), in the environment's user.reg.
    public static func signedIn(bottleURL: URL) -> UInt64? {
        guard let text = try? String(contentsOf: bottleURL.appending(path: "user.reg"), encoding: .utf8) else { return nil }
        return activeUser(inRegistry: text)
    }

    static func activeUser(inRegistry text: String) -> UInt64? {
        guard let match = text.firstMatch(of: #/"ActiveUser"=dword:([0-9a-fA-F]{8})/#),
              let account = UInt64(match.1, radix: 16), account != 0 else { return nil }
        return steamIDBase + account
    }

    /// What a Steam game's page says about accounts, or nil when there is nothing worth saying:
    /// one account on this Steam, or no record of who installed the game.
    public struct GameNote: Sendable, Equatable {
        public let installedBy: SteamAccount
        /// The account Steam is signed in to, or signed in to last when it is not running, when
        /// that is another one.
        public let otherAccount: SteamAccount?
        /// Whether Steam runs now; when not, `otherAccount` is the one it signed in to last.
        public let steamRunning: Bool
    }

    public static func note(installedBy owner: UInt64?, accounts: [SteamAccount], signedIn: UInt64?) -> GameNote? {
        guard accounts.count > 1, let owner, let installer = accounts.first(where: { $0.id == owner }) else { return nil }
        let current = signedIn.flatMap { id in accounts.first { $0.id == id } } ?? (signedIn == nil ? accounts.first : nil)
        return GameNote(installedBy: installer, otherAccount: current.flatMap { $0.id == owner ? nil : $0 }, steamRunning: signedIn != nil)
    }
}

// MARK: Whose games

extension SteamAccounts {
    /// When each account first signed in to this Steam: its userdata folder is made then.
    public static func firstSignIns(steamRoot: URL) -> [UInt64: Date] {
        let userdata = steamRoot.appending(path: "userdata", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: userdata, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return Dictionary(folders.compactMap { folder in
            guard let account = UInt64(folder.lastPathComponent),
                  let made = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate else { return nil }
            return (steamIDBase + account, made)
        }, uniquingKeysWith: min)
    }

    /// Games that appeared in the library (OwnedSteamGame.cachedAt) while only one account had
    /// ever signed in to this Steam: that account's. On a Steam one person used alone before a
    /// second signed in, that is the whole first library. Later arrivals are noteArrivals'.
    public static func earlyArrivals(_ appeared: [Int: Date], firstSignIns: [UInt64: Date]) -> [Int: UInt64] {
        let order = firstSignIns.sorted { $0.value < $1.value }
        guard let first = order.first else { return [:] }
        let secondSignIn = order.dropFirst().first?.value ?? .distantFuture
        return appeared.filter { $0.value < secondSignIn }.mapValues { _ in first.key }
    }

    /// Whose a Steam game is, as far as this Mac can tell, and why: what the player chose, else
    /// every account with a sign of it (installed it, or was the one signed in when it first
    /// appeared in the library). Ownership itself is not readable (the license list is encrypted).
    public struct Owners: Sendable, Equatable {
        public enum Reason: Sendable, Equatable { case chosen, installed, added }
        public let accounts: Set<UInt64>
        /// The strongest sign among them.
        public let reason: Reason

        public init(accounts: Set<UInt64>, reason: Reason) { self.accounts = accounts; self.reason = reason }
    }

    /// Puts the games among `appIDs` not seen before down to the account signed in, and marks
    /// them seen. The first look of all only marks: when those games arrived is not known.
    /// Returns whether anything changed.
    @discardableResult
    public static func noteArrivals(_ appIDs: Set<Int>, signedIn: UInt64?, firstLook: Bool,
                                    seen: inout Set<Int>, added: inout [Int: UInt64]) -> Bool {
        let new = appIDs.subtracting(seen)
        guard !new.isEmpty else { return false }
        if !firstLook, let signedIn { for id in new { added[id] = signedIn } }
        seen.formUnion(new)
        return true
    }

    public static func owners(appID: Int, installedBy: UInt64?, added: [Int: UInt64],
                              chosen: [Int: Set<UInt64>]) -> Owners? {
        if let picked = chosen[appID], !picked.isEmpty { return Owners(accounts: picked, reason: .chosen) }
        var accounts = Set<UInt64>()
        var reason: Owners.Reason?
        if let installedBy { accounts.insert(installedBy); reason = .installed }
        if let adder = added[appID] { accounts.insert(adder); reason = reason ?? .added }
        return reason.map { Owners(accounts: accounts, reason: $0) }
    }
}

/// Valve's text KeyValues (loginusers.vdf): quoted keys and values, nested
/// blocks in braces, backslash escapes, // comments. Keys are matched without case, as Steam does.
enum TextKeyValues {
    indirect enum Node {
        case string(String)
        case block([(key: String, value: Node)])

        var string: String? { if case let .string(s) = self { return s }; return nil }
        var children: [(key: String, value: Node)] { if case let .block(b) = self { return b }; return [] }
        func child(_ key: String) -> Node? { children.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value }
    }

    static func parse(_ text: String) -> Node {
        var tokens = tokenize(text)[...]
        return .block(block(&tokens))
    }

    private enum Token: Equatable { case word(String), open, close }

    private static func block(_ tokens: inout ArraySlice<Token>) -> [(key: String, value: Node)] {
        var entries: [(key: String, value: Node)] = []
        while let token = tokens.popFirst() {
            guard case let .word(key) = token else {
                if token == .close { return entries }
                continue   // a stray brace: skipped
            }
            switch tokens.first {
            case .word(let value)?: tokens.removeFirst(); entries.append((key, .string(value)))
            case .open?: tokens.removeFirst(); entries.append((key, .block(block(&tokens))))
            default: break
            }
        }
        return entries
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var chars = Array(text.unicodeScalars)[...]
        while let c = chars.popFirst() {
            switch c {
            case "{": tokens.append(.open)
            case "}": tokens.append(.close)
            case "\"":
                var word = String.UnicodeScalarView()
                while let d = chars.popFirst(), d != "\"" {
                    guard d == "\\", let e = chars.popFirst() else { word.append(d); continue }
                    switch e {
                    case "n": word.append("\n")
                    case "t": word.append("\t")
                    default: word.append(e)   // \" and \\ and anything else: the character itself
                    }
                }
                tokens.append(.word(String(word)))
            case "/" where chars.first == "/":
                while let d = chars.popFirst(), d != "\n" {}
            case _ where CharacterSet.whitespacesAndNewlines.contains(c):
                continue
            default:   // an unquoted word runs to whitespace or a brace
                var word = String.UnicodeScalarView([c])
                while let d = chars.first, d != "{", d != "}", d != "\"", !CharacterSet.whitespacesAndNewlines.contains(d) {
                    word.append(d); chars.removeFirst()
                }
                tokens.append(.word(String(word)))
            }
        }
        return tokens
    }
}
