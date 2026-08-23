import Foundation

/// Minimal process helpers. Wine itself is launched through `WineRunner`, which streams output;
/// these are for short tools (tar, xattr, wine --version, reg queries).
public enum Shell {
    @discardableResult
    public static func capture(_ executable: String, _ args: [String], env: [String: String]? = nil, cwd: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw HighballError.processFailed(command: ([executable] + args).joined(separator: " "), status: p.terminationStatus, output: text)
        }
        return text
    }

    public static func run(_ executable: String, _ args: [String], env: [String: String]? = nil) throws {
        _ = try capture(executable, args, env: env)
    }
}
