import Foundation

/// Minimal process helpers. Wine itself is launched through `WineRunner`, which streams output;
/// these are for short tools (tar, xattr, wine --version, reg queries).
public enum Shell {
    /// Runs a tool and returns everything it printed, optionally copying it to `log` as it comes.
    ///
    /// The log matters for the long ones. A winetricks verb downloads from servers Highball does
    /// not run and can take forty minutes, and until 2026-09-22 it wrote nothing anywhere: three
    /// reports of the core fonts failing (highball#135, #180, #183) arrived with the game's launch
    /// log attached, because that was the newest file in the folder and the only thing there was
    /// to attach. The output is streamed rather than kept for the end, so a step that hangs still
    /// leaves what it managed to say.
    @discardableResult
    public static func capture(_ executable: String, _ args: [String], env: [String: String]? = nil, cwd: URL? = nil,
                               log: URL? = nil, logHeader: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        var handle: FileHandle?
        if let log {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            handle = try? FileHandle(forWritingTo: log)
            let header = (logHeader.map { $0 + "\n" } ?? "") + "# " + ([executable] + args).joined(separator: " ") + "\n"
            try? handle?.write(contentsOf: Data(header.utf8))
        }
        defer { try? handle?.close() }
        let started = Date()
        try p.run()
        var data = Data()
        let reader = out.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            try? handle?.write(contentsOf: chunk)
        }
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        // The same footer a Wine launch writes, so a failed step is told from a finished one by
        // looking at the end of the file (the exit code used to be thrown away, issue #36).
        try? handle?.write(contentsOf: Data("# exit=\(p.terminationStatus) after \(Int(Date().timeIntervalSince(started)))s\n".utf8))
        guard p.terminationStatus == 0 else {
            throw HighballError.processFailed(command: ([executable] + args).joined(separator: " "), status: p.terminationStatus, output: text)
        }
        return text
    }

    public static func run(_ executable: String, _ args: [String], env: [String: String]? = nil) throws {
        _ = try capture(executable, args, env: env)
    }
}
