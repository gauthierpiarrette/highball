import XCTest
@testable import HighballKit

/// winetricks runs under /bin/bash, which drops the DYLD_* variables under SIP, and the Wine 11
/// engines then found no FreeType during every winetricks install (highball#241).
final class WinetricksWineTests: XCTestCase {
    func testTheLibraryPathsTravelUnderOtherNames() {
        let wine = URL(fileURLWithPath: "/engines/x/engine/bin/wine"), script = URL(fileURLWithPath: "/hb/tools/winetricks-wine/wine")
        let env = WinetricksWine.environment(["DYLD_FALLBACK_LIBRARY_PATH": "/a b/frameworks:/c", "WINE": wine.path,
                                              "WINE_BIN": wine.path, "WINEPREFIX": "/p"], wine: wine, script: script)
        XCTAssertEqual(env["WINE"], script.path, "winetricks starts the script")
        XCTAssertEqual(env["HB_WINE"], wine.path, "the script starts the engine's wine")
        XCTAssertEqual(env["WINE_BIN"], wine.path, "winetricks reads the architecture off the real binary")
        XCTAssertEqual(env["HB_KEEP_DYLD_FALLBACK_LIBRARY_PATH"], "/a b/frameworks:/c")
        XCTAssertEqual(env["DYLD_FALLBACK_LIBRARY_PATH"], "/a b/frameworks:/c", "a run where DYLD gets through keeps it")
        XCTAssertNil(env["HB_KEEP_DYLD_LIBRARY_PATH"], "nothing is invented for a variable the environment does not set")
        XCTAssertEqual(env["WINEPREFIX"], "/p")
    }

    /// The script's loop, run by /bin/sh the way winetricks reaches it: a path with spaces comes back
    /// whole, and a variable with nothing kept stays unset.
    func testTheScriptPutsThePathsBack() throws {
        let body = WinetricksWine.script.replacingOccurrences(of: "exec \"$HB_WINE\" \"$@\"", with: "export -p")
        XCTAssertNotEqual(body, WinetricksWine.script)
        let out = try run(["-c", body], env: ["HB_KEEP_DYLD_FALLBACK_LIBRARY_PATH": "/Users/x/Library/Application Support/Highball/engines/r/frameworks:/y"])
        // export -p quotes the way the shell likes (bash double, dash single), so the quotes are left out.
        let exported = out.split(separator: "\n").map { line -> String in
            var s = String(line)
            for prefix in ["export ", "declare -x "] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
            return s.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        }
        XCTAssertTrue(exported.contains("DYLD_FALLBACK_LIBRARY_PATH=/Users/x/Library/Application Support/Highball/engines/r/frameworks:/y"), out)
        XCTAssertFalse(exported.contains { $0.hasPrefix("DYLD_LIBRARY_PATH") }, out)
    }

    func testTheScriptStartsWineWithItsArguments() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hb-wtw-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try WinetricksWine.installScript(in: HighballPaths(home: dir))
        XCTAssertEqual(try WinetricksWine.installScript(in: HighballPaths(home: dir)), script, "a second call keeps the same file")
        let stub = dir.appending(path: "stub-wine")
        try Data("#!/bin/sh\necho \"wine got: $*\"\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let out = try run(["-c", "\"$0\" cmd.exe /c 'echo %AppData%'", script.path], env: ["HB_WINE": stub.path])
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "wine got: cmd.exe /c echo %AppData%")
    }

    /// `highball tricks` built its PATH from the engine and the system folders only, so a verb that
    /// shells out to cabextract failed from the CLI while the same recipe step worked (db#941).
    func testToolFoldersGoInFrontOfThePathBothCallersGive() throws {
        let tools = FileManager.default.temporaryDirectory.appending(path: "hb-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tools); unsetenv("HIGHBALL_TOOLS") }
        let engineBin = "/engines/e/engine/bin:/usr/bin:/bin"
        unsetenv("HIGHBALL_TOOLS")
        let without = WinetricksWine.pathWithTools(engineBin)
        XCTAssertTrue(without?.hasSuffix(engineBin) == true)
        setenv("HIGHBALL_TOOLS", tools.path, 1)
        XCTAssertEqual(WinetricksWine.pathWithTools(engineBin)?.split(separator: ":").first.map(String.init), tools.path)
        XCTAssertTrue(WinetricksWine.pathWithTools(engineBin)?.hasSuffix(engineBin) == true, "the engine's folders stay")
        setenv("HIGHBALL_TOOLS", tools.appending(path: "missing").path, 1)
        XCTAssertEqual(WinetricksWine.pathWithTools(engineBin), without, "a folder that is not there is not added")
    }

    private func run(_ args: [String], env: [String: String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = args
        p.environment = ["PATH": "/usr/bin:/bin"].merging(env) { $1 }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
