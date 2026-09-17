import Foundation

/// Wine's emulated display mode changes, per program. A game that asks Windows for a fullscreen
/// mode the Mac cannot switch to gets "success" while the display stays as it is, so it opens
/// small, off-centre, with black bars, or refuses to start; with EmulateModeset Wine pretends
/// the change happened and scales the window to the real screen. win32u reads the value under
/// `Software\Wine\X11 Driver` whatever the display driver (the Mac driver included, measured
/// in the engine's win32u.so), and `AppDefaults\<exe>` scopes it to one program, which is what
/// the Five Nights at Freddy's recipe writes and what was verified by eye. Never a default: games
/// that switch modes for real exist, so the value is set per program, by a recipe or by hand.
/// The bottle's registry is the only state; nothing is stored beside it.
public enum DisplayModeEmulation {
    public static let valueName = "EmulateModeset"

    /// The per-program key, as `reg add` wants it.
    public static func key(forExecutable exe: URL) -> String {
        "HKCU\\Software\\Wine\\AppDefaults\\\(exe.lastPathComponent)\\X11 Driver"
    }

    /// Whether the bottle turns it on for `exe`, read from user.reg without running Wine.
    public static func isOn(in bottle: Bottle, executable exe: URL) -> Bool {
        guard let text = try? String(contentsOf: bottle.url.appending(path: "user.reg"), encoding: .utf8) else { return false }
        return isOn(userReg: text, executableName: exe.lastPathComponent)
    }

    /// Pure: the registry text says `"EmulateModeset"="y"` under the program's X11 Driver key.
    public static func isOn(userReg: String, executableName: String) -> Bool {
        let raw = RegistryText.value(in: userReg, key: "Software\\Wine\\AppDefaults\\\(executableName)\\X11 Driver", name: valueName) ?? ""
        return raw.lowercased() == "\"y\""
    }

    /// Turns it on or off for `exe` through the bottle's Wine. Programs read the registry when
    /// they start, so a running Steam client needs no restart for the next launch to see it.
    public static func set(_ on: Bool, in runner: WineRunner, executable exe: URL) async throws {
        let key = key(forExecutable: exe)
        if on {
            try await runner.regAdd(key: key, name: valueName, type: "REG_SZ", data: "y")
        } else {
            try await runner.regDelete(key: key, name: valueName)
        }
    }
}
