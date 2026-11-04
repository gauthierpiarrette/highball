import Foundation
import os

/// GOG games without GOG Galaxy (highball#8, #149). Galaxy's sign-in window is Chromium inside Qt
/// WebEngine, which draws black on the Wine 10 engines and crashes on the Wine 11 ones, so the
/// client cannot sign in under Wine at all. Its jobs are done here by the tools Heroic uses:
/// gogdl (github.com/Heroic-Games-Launcher/heroic-gogdl, GPL-3 like Highball) signs in, downloads
/// a game's Windows build straight into an environment, fetches the Windows runtimes it lists and
/// syncs cloud saves; comet (github.com/imLinguin/comet, Apache-2.0) stands in for Galaxy's
/// communication service while a game runs, so achievements, stats and play time reach the
/// player's GOG account. Sign-in happens on GOG's own page in the player's browser.
///
/// Install state is read from disk rather than kept: every GOG game, whether gogdl downloaded it
/// or an offline installer from gog.com put it there, carries a goggame-<id>.info naming its id,
/// title, build and launch tasks. So a game installed by hand earlier shows up as the GOG game it
/// is, with its cover, and there is no record to go stale when a folder is deleted.
public struct GOGStore: Sendable {
    public let paths: HighballPaths
    public init(paths: HighballPaths = HighballPaths()) { self.paths = paths }

    // Pinned like an engine component. Update deliberately, never float.
    static let gogdl = EngineManifest.Component(
        kind: "tool", url: URL(string: "https://github.com/Heroic-Games-Launcher/heroic-gogdl/releases/download/v1.3.1/gogdl_macos_arm64")!,
        sha256: "33a6d9b329c35f1caa7968009bf2f4f0a6f57cd00f749a4d2cb2204f3e794d2e", size: 11_031_600,
        license: nil, optional: nil, acceptance: nil, extract: nil, note: nil, version: "1.3.1")
    static let comet = EngineManifest.Component(
        kind: "tool", url: URL(string: "https://github.com/imLinguin/comet/releases/download/v0.4.0/comet-aarch64-apple-darwin")!,
        sha256: "53152b17b86baf118f47a299c83e8dc101653655da7d9d9a6aa36bfeb982c489", size: 11_209_264,
        license: nil, optional: nil, acceptance: nil, extract: nil, note: nil, version: "0.4.0")
    /// comet's GalaxyCommunication.exe placeholder: some Galaxy SDK versions refuse to talk to
    /// anything until a Windows service of that name is registered (comet's dummy-service/README).
    static let dummyService = EngineManifest.Component(
        kind: "tool", url: URL(string: "https://github.com/imLinguin/comet/releases/download/v0.4.0/dummy-service.zip")!,
        sha256: "4a3bb0889662a976fb84445c46eafbe44f7b9c8ea761a5761266f451e4dfcaf7", size: 36_795,
        license: nil, optional: nil, acceptance: nil, extract: nil, note: nil, version: "0.4.0")

    /// Galaxy's public client, the one gogdl, Heroic, Lutris and comet all sign in as.
    static let clientID = "46899977096215655"

    /// GOG's sign-in page, opened in the player's own browser so the password never passes through
    /// Highball. It ends on embed.gog.com/on_login_success?origin=client&code=…, and the player
    /// pastes that address (or just the code) back.
    public static let loginURL = URL(string: "https://auth.gog.com/auth?client_id=\(clientID)&layout=galaxy&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient&response_type=code")!

    public var gogdlBinary: URL { paths.home.appending(path: "tools/gogdl", directoryHint: .notDirectory) }
    public var cometBinary: URL { paths.home.appending(path: "tools/comet", directoryHint: .notDirectory) }
    var dir: URL { paths.home.appending(path: "gog", directoryHint: .isDirectory) }
    var authFile: URL { dir.appending(path: "auth.json") }
    var userFile: URL { dir.appending(path: "user.json") }
    var dummyServiceDir: URL { paths.home.appending(path: "tools/comet-dummy-service", directoryHint: .isDirectory) }

    /// Downloads and verifies a pinned tool when it is missing, or when the file there is not the
    /// pinned build: a pin moved to a newer gogdl or comet reaches existing installs, and a
    /// damaged copy is replaced. The new file is written beside the old one and renamed over it,
    /// so a gogdl or comet running at that moment keeps its own file and nothing ever runs half a
    /// copy.
    func ensure(_ component: EngineManifest.Component, name: String, at binary: URL,
                progress: DownloadProgress?) async throws -> URL {
        if isPinned(binary, sha256: component.sha256) { return binary }
        let file = try await EngineStore(paths: paths).download(component, name: name, progress: progress)
        let folder = binary.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appending(path: ".\(binary.lastPathComponent).\(UUID().uuidString).new")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: file, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        // Checksum-verified above; quarantine would otherwise block the unsigned binaries.
        try? Shell.run("/usr/bin/xattr", ["-c", staged.path])
        guard rename(staged.path, binary.path) == 0 else {
            throw HighballError.failed("Could not put \(name) in place: \(String(cString: strerror(errno)))")
        }
        Self.rememberVerified(binary, sha256: component.sha256)
        return binary
    }

    /// Files whose checksum matched, by path, with the size and modification date they had then:
    /// a tool is hashed again only when it changed, not on every sign-in check or launch.
    private static let verified = OSAllocatedUnfairLock(initialState: [String: (size: Int64, modified: Date, sha256: String)]())

    /// Whether the file at `binary` is the pinned build.
    func isPinned(_ binary: URL, sha256 expected: String) -> Bool {
        guard let stamp = Self.fileStamp(binary) else { return false }
        let expected = expected.lowercased()
        if let known = Self.verified.withLock({ $0[binary.path] }), known.size == stamp.size, known.modified == stamp.modified {
            return known.sha256 == expected
        }
        guard let actual = try? EngineStore(paths: paths).sha256(of: binary) else { return false }
        Self.verified.withLock { $0[binary.path] = (stamp.size, stamp.modified, actual) }
        return actual == expected
    }

    private static func rememberVerified(_ binary: URL, sha256: String) {
        guard let stamp = fileStamp(binary) else { return }
        verified.withLock { $0[binary.path] = (stamp.size, stamp.modified, sha256.lowercased()) }
    }

    private static func fileStamp(_ url: URL) -> (size: Int64, modified: Date)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return (size, modified)
    }

    public func ensureInstalled(progress: DownloadProgress? = nil) async throws {
        _ = try await ensure(Self.gogdl, name: "gogdl", at: gogdlBinary, progress: progress)
    }

    /// comet and its placeholder service. Failing here never stops a launch (see GOGComet). The
    /// service is unpacked again when the pinned archive changes: the archive's checksum is kept
    /// beside it.
    public func ensureComet(progress: DownloadProgress? = nil) async throws -> (comet: URL, service: URL) {
        let comet = try await ensure(Self.comet, name: "comet", at: cometBinary, progress: progress)
        let exe = dummyServiceDir.appending(path: "GalaxyCommunication.exe")
        let stamp = dummyServiceDir.appending(path: ".sha256")
        let unpacked = (try? String(contentsOf: stamp, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !FileManager.default.fileExists(atPath: exe.path) || unpacked != Self.dummyService.sha256.lowercased() {
            let zip = try await EngineStore(paths: paths).download(Self.dummyService, name: "comet-dummy-service", progress: progress)
            try FileManager.default.createDirectory(at: dummyServiceDir, withIntermediateDirectories: true)
            try Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, dummyServiceDir.path])
            try? Self.dummyService.sha256.lowercased().write(to: stamp, atomically: true, encoding: .utf8)
        }
        return (comet, exe)
    }

    /// gogdl keeps its manifests under $GOGDL_CONFIG_PATH/heroic_gogdl; inside the Highball home
    /// they move with it, and deleting the home stays a full uninstall.
    var environment: [String: String] { ["GOGDL_CONFIG_PATH": dir.path] }

    /// The arguments every gogdl call starts with.
    var baseArguments: [String] { ["--auth-config-path", authFile.path] }

    /// gogdl reads auth.json when it starts and rewrites it in place when it refreshes a token, so
    /// two calls at once can put a stale token pair back, or read a half-written file and look
    /// signed out. The short calls take turns; downloads, which run for minutes, do not.
    private static let authFileLock = NSLock()
    func withAuthFile<T>(_ body: () throws -> T) rethrows -> T { try Self.authFileLock.withLock(body) }

    /// Captures stdout only: gogdl logs to stderr and prints its JSON to stdout.
    @discardableResult
    func capture(_ args: [String]) throws -> String {
        try withAuthFile { try captureUnlocked(args) }
    }

    private func captureUnlocked(_ args: [String]) throws -> String {
        secureDirectory()
        let p = Process()
        p.executableURL = gogdlBinary
        p.arguments = baseArguments + args
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        // Read stderr alongside: a full pipe would otherwise stall gogdl on a long call.
        let errData = OSAllocatedUnfairLock(initialState: Data())
        let errRead = DispatchGroup()
        DispatchQueue.global().async(group: errRead) {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            errData.withLock { $0 = data }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        errRead.wait()
        guard p.terminationStatus == 0 else {
            throw HighballError.processFailed(command: "gogdl " + (args.first ?? ""),
                                              status: p.terminationStatus,
                                              output: Self.redacted(String(decoding: errData.withLock { $0 }.suffix(2000), as: UTF8.self)))
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs gogdl streaming each output line (downloads are long and progress matters). `control`
    /// stops it the way Ctrl-C in a terminal does; gogdl keeps the progress and resumes.
    @discardableResult
    public func runStreaming(_ args: [String], control: LegendaryControl? = nil,
                             onLine: (@Sendable (String) -> Void)? = nil) throws -> Int32 {
        secureDirectory()
        let p = Process()
        p.executableURL = gogdlBinary
        p.arguments = baseArguments + args
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        control?.started(p)
        let reader = pipe.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                onLine?(Self.redacted(String(decoding: buffer[..<nl], as: UTF8.self)))
                buffer.removeSubrange(...nl)
            }
        }
        if !buffer.isEmpty { onLine?(Self.redacted(String(decoding: buffer, as: UTF8.self))) }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: Signing in

    public var isAuthenticated: Bool { FileManager.default.fileExists(atPath: authFile.path) }

    /// What the player pasted into the sign-in sheet, read before anything is sent anywhere, so
    /// the sheet can say what is wrong while they are still on it.
    public enum PastedSignIn: Equatable, Sendable {
        case empty
        case code(String)
        /// GOG's sign-in page itself (auth.gog.com, login.gog.com): copied before logging in.
        case signInPage
        /// A gog.com address without a code, such as the store or the account page.
        case noCode
        /// Not a GOG address, or not shaped like a code. Nothing from it is used.
        case notGOG
    }

    /// Reads the whole on_login_success address (with or without its scheme) or the bare code.
    /// A code is only ever taken from a gog.com address, so a pasted link from anywhere else
    /// never reaches gogdl.
    public static func readSignIn(_ pasted: String) -> PastedSignIn {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        let isCode: (String) -> Bool = { value in
            value.count >= 8 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
        guard text.contains("/") || text.contains("?") || text.contains(".") else {
            return isCode(text) ? .code(text) : .notGOG
        }
        guard !text.contains(where: \.isWhitespace),
              let components = URLComponents(string: text.contains("://") ? text : "https://" + text),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              // The encoded host, checked by character: "evil.com%2F.gog.com" decodes to a host
              // that ends in .gog.com.
              let host = components.percentEncodedHost?.lowercased(),
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              host == "gog.com" || host.hasSuffix(".gog.com") else {
            return .notGOG
        }
        if let code = components.queryItems?.first(where: { $0.name == "code" })?.value, isCode(code) {
            return .code(code)
        }
        return host == "auth.gog.com" || host == "login.gog.com" ? .signInPage : .noCode
    }

    public static func authorizationCode(from pasted: String) -> String? {
        if case let .code(code) = readSignIn(pasted) { return code }
        return nil
    }

    /// gogdl's output with token values blanked, for anything shown or written to a log: its
    /// errors can echo the token reply, and a log can end up pasted into a public issue.
    static func redacted(_ text: String) -> String {
        let patterns = [
            #"(["']?(?:access_token|refresh_token|id_token|session_id)["']?\s*[:=]\s*["']?)[^"'&\s,}]+"#,
            #"(\b(?:code|token)=)[^&\s"']+"#,
            #"(--code\s+)\S+"#,
            #"(Bearer\s+)\S+"#,
        ]
        return patterns.reduce(text) {
            $0.replacingOccurrences(of: $1, with: "$1[redacted]", options: [.regularExpression, .caseInsensitive])
        }
    }

    /// The folder holding the tokens, the account's game list and the save records: this user
    /// only, whatever mode the files inside are written with.
    func secureDirectory() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    public func authenticate(code: String) throws {
        secureDirectory()
        // A refused code must not cost a working sign-in: keep the current tokens to put back.
        let previous = try? Data(contentsOf: authFile)
        let out: String
        do {
            out = try capture(["auth", "--code", code])
        } catch {
            restore(previous)
            throw HighballError.failed("Highball could not finish connecting to GOG. Check your internet connection, then try again.")
        }
        // gogdl prints {"error": true} and exits 0 when GOG refuses the code.
        guard let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              obj["access_token"] != nil else {
            restore(previous)
            throw HighballError.failed("That link has expired or was already used. Click Open GOG sign-in again: GOG gives you a fresh link straight away, often without asking for your password.")
        }
        protectAuthFile()
        _ = try? refreshUser()
    }

    /// Puts back the sign-in a failed attempt may have overwritten (or none, if there was none).
    private func restore(_ previous: Data?) {
        if let previous {
            try? previous.write(to: authFile, options: .atomic)
            protectAuthFile()
        } else {
            try? FileManager.default.removeItem(at: authFile)
        }
    }

    /// gogdl writes the tokens with the default file mode and rewrites them on every refresh;
    /// they are the account's keys, so only this user reads them.
    func protectAuthFile() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)
    }

    public func logout() {
        try? FileManager.default.removeItem(at: authFile)
        try? FileManager.default.removeItem(at: userFile)
    }

    public struct Credentials: Sendable {
        public let accessToken: String
        public let refreshToken: String
        public let userID: String
    }

    /// Current tokens. gogdl refreshes the access token when it has expired and saves the new pair,
    /// so this is the one place tokens come from. Never log or persist the result elsewhere.
    public func credentials() throws -> Credentials {
        let out = try capture(["auth"])
        protectAuthFile()   // `auth` may have just written a refreshed pair
        guard let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let access = obj["access_token"] as? String, let refresh = obj["refresh_token"] as? String else {
            throw HighballError.failed("GOG signed this Mac out. Connect your GOG account again.")
        }
        let user = (obj["user_id"] as? String) ?? (obj["user_id"] as? NSNumber)?.stringValue ?? ""
        return Credentials(accessToken: access, refreshToken: refresh, userID: user)
    }

    /// The account's name, which comet needs. Kept beside the tokens; no secret in it.
    public var username: String? {
        guard let data = try? Data(contentsOf: userFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["username"] as? String
    }

    @discardableResult
    public func refreshUser() throws -> String? {
        let creds = try credentials()
        var request = URLRequest(url: URL(string: "https://embed.gog.com/userData.json")!)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        let data = try Self.fetch(request)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["username"] as? String else { return nil }
        try JSONSerialization.data(withJSONObject: ["username": name]).write(to: userFile, options: .atomic)
        return name
    }

    /// A GET for async callers: the wait holds no thread, so the library's parallel lookups
    /// leave the shared pool free.
    static func fetch(async request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HighballError.invalid("HTTP \(http.statusCode) for \(request.url?.absoluteString ?? "")")
        }
        return data
    }

    /// A blocking GET for callers already off the main thread (gogdl-side work, one request at a time).
    static func fetch(_ request: URLRequest) throws -> Data {
        guard let data = try fetch(request, missingIsNil: false) else { throw HighballError.invalid("no data") }
        return data
    }

    /// The same, but nil when the server answers 404: the thing asked for doesn't exist. Network
    /// failures and other statuses still throw.
    static func fetchIfFound(_ request: URLRequest) throws -> Data? {
        try fetch(request, missingIsNil: true)
    }

    private static func fetch(_ request: URLRequest, missingIsNil: Bool) throws -> Data? {
        var request = request
        request.timeoutInterval = 30
        let result = OSAllocatedUnfairLock<(data: Data?, failure: String?)>(initialState: (nil, nil))
        let address = request.url?.absoluteString ?? ""
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let found: (Data?, String?) = if let error { (nil, error.localizedDescription) }
                else if missingIsNil, status == 404 { (nil, nil) }
                else if let status, !(200..<300).contains(status) { (nil, "HTTP \(status) for \(address)") }
                else { (data ?? Data(), nil) }
            result.withLock { $0 = found }
            done.signal()
        }.resume()
        done.wait()
        let (data, failure) = result.withLock { $0 }
        if let failure { throw HighballError.invalid(failure) }
        return data
    }
}
