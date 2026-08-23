import Foundation

public struct LaunchResult: Sendable {
    public let exitStatus: Int32
    public let duration: TimeInterval
    public let log: URL
    /// Heuristic: exited non-zero (or at all) within 10 s of launch. The app uses this to suggest another renderer.
    public var crashedEarly: Bool { duration < 10 && exitStatus != 0 }
}

/// Launches Wine processes for a bottle and captures their output to `logs/`.
public struct WineRunner: Sendable {
    public let paths: HighballPaths
    public let engine: InstalledEngine
    public let bottle: Bottle

    public init(paths: HighballPaths = HighballPaths(), engine: InstalledEngine, bottle: Bottle) {
        self.paths = paths
        self.engine = engine
        self.bottle = bottle
    }

    /// Runs `wine <args>` and waits. `onOutput` receives each line of combined stdout/stderr.
    @discardableResult
    public func run(
        _ args: [String],
        renderer: Renderer? = nil,
        extraEnvironment: [String: String] = [:],
        label: String? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> LaunchResult {
        try paths.ensure()
        let env = try bottle.environment(engine: engine, renderer: renderer, extra: extraEnvironment)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let logURL = paths.logs.appending(path: "\(stamp)-\(bottle.name)-\(label ?? args.first ?? "wine").log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        let header = "# gin \(engine.id) bottle=\(bottle.name) renderer=\(renderer ?? bottle.settings.renderer)\n# wine \(args.joined(separator: " "))\n"
        logHandle.write(Data(header.utf8))

        let process = Process()
        process.executableURL = engine.wineBinary
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        process.currentDirectoryURL = bottle.driveC
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let start = Date()
        try process.run()

        let reader = pipe.fileHandleForReading
        let status: Int32 = await withCheckedContinuation { cont in
            process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
            // Drain synchronously on a background thread; `readDataToEndOfFile` returns at EOF.
            DispatchQueue.global(qos: .utility).async {
                var buffer = Data()
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    logHandle.write(chunk)
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: buffer[..<nl], as: UTF8.self)
                        buffer.removeSubrange(...nl)
                        onOutput?(line)
                    }
                }
                if !buffer.isEmpty { onOutput?(String(decoding: buffer, as: UTF8.self)) }
            }
        }
        try? logHandle.close()
        return LaunchResult(exitStatus: status, duration: Date().timeIntervalSince(start), log: logURL)
    }

    /// Runs the executable directly under `wine` (not `start /unix`) so the process stays attached and
    /// everything it and its children print lands in the log. The call returns when the program exits.
    @discardableResult
    public func start(_ executable: URL, arguments: [String] = [], renderer: Renderer? = nil, extraEnvironment: [String: String] = [:], onOutput: (@Sendable (String) -> Void)? = nil) async throws -> LaunchResult {
        try await run([executable.path] + arguments, renderer: renderer, extraEnvironment: extraEnvironment, label: executable.lastPathComponent, onOutput: onOutput)
    }

    /// Runs the pinned program, honouring its own renderer/env/args.
    @discardableResult
    public func start(pin: Pin, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> LaunchResult {
        let exe = bottle.driveC.appending(path: pin.path)
        return try await start(exe, arguments: pin.arguments, renderer: pin.renderer, extraEnvironment: pin.environment, onOutput: onOutput)
    }

    public func wineboot() async throws -> LaunchResult {
        try await run(["wineboot", "-u"], renderer: .wined3d, label: "wineboot")
    }

    public func kill() throws {
        let env = try bottle.environment(engine: engine, renderer: .wined3d)
        try Shell.run(engine.wineserverBinary.path, ["-k"], env: env)
    }

    // MARK: Registry helpers

    public func regAdd(key: String, name: String, type: String, data: String) async throws {
        _ = try await run(["reg", "add", key, "/v", name, "/t", type, "/d", data, "/f"], renderer: .wined3d, label: "reg")
    }

    public func regQuery(key: String, name: String) async throws -> String? {
        var lines: [String] = []
        let collector = Collector()
        _ = try await run(["reg", "query", key, "/v", name], renderer: .wined3d, label: "reg") { collector.append($0) }
        lines = collector.lines
        guard let line = lines.first(where: { $0.contains("REG_") }) else { return nil }
        return line.split(whereSeparator: \.isWhitespace).last.map(String.init)
    }

    public func setWindowsVersion(_ v: WindowsVersion) async throws {
        _ = try await run(["winecfg", "-v", v.rawValue], renderer: .wined3d, label: "winecfg")
    }
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
