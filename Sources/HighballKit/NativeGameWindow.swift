import Foundation

/// Per-executable Mac driver policy, read by Wine when the game process starts.
public enum NativeGameWindow: String, CaseIterable, Sendable {
    case standard = "n"
    case native = "y"
    case freeCursor = "free"

    static let valueName = "NativeGameWindow"

    static func registryPath(for executable: URL) -> String {
        "Software\\Wine\\AppDefaults\\\(executable.lastPathComponent)\\Mac Driver"
    }

    public static func read(in bottle: Bottle, executable: URL) -> Self {
        guard let text = try? String(contentsOf: bottle.url.appending(path: "user.reg"), encoding: .utf8) else {
            return .standard
        }
        return read(userReg: text, executable: executable)
    }

    static func read(userReg: String, executable: URL) -> Self {
        let value = RegistryText.value(in: userReg, key: registryPath(for: executable), name: valueName)
        return Self.allCases.first { value?.lowercased() == "\"\($0.rawValue)\"" } ?? .standard
    }

    public func write(in runner: WineRunner, executable: URL) async throws {
        let key = "HKCU\\\(Self.registryPath(for: executable))"
        let result = try await runner.run(["reg", "add", key, "/v", Self.valueName, "/t", "REG_SZ", "/d", rawValue, "/f"],
                                          renderer: .wined3d, label: "reg")
        guard result.exitStatus == 0 else {
            throw HighballError.processFailed(command: "reg add", status: result.exitStatus, output: "see \(result.log.path)")
        }
    }
}
