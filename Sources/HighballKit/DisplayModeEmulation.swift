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

    /// What a fullscreen size the Mac never switched to leaves in a launch log: win32u gives up
    /// on the display it was told to change, once per attempt. The game then draws at the size it
    /// asked for inside a window that stayed the size it was, which is the corner window with the
    /// pointer landing somewhere other than what is drawn — highball#67 (Five Nights at Freddy's)
    /// and #103 (Dead Rising 3) are the same report, and switching graphics modes never moved it.
    public static let unswitchedMarker = "err:system:display_mode_changed"

    /// Whether a launch log shows a game asking for a mode change that never happened. Two
    /// sightings, not one: a lone failure can be a screen waking up or a monitor being plugged
    /// in, while a game that wants a mode the Mac will not give asks again on every attempt.
    public static func looksUnswitched(inLog text: String, atLeast: Int = 2) -> Bool {
        text.split(separator: "\n").filter { $0.contains(unswitchedMarker) }.count >= atLeast
    }

    /// The same question for a log on disk, read head-and-tail so a log of many megabytes — what
    /// a long session leaves — costs a bounded read.
    public static func looksUnswitched(log url: URL, atLeast: Int = 2) -> Bool {
        guard let text = BugReport.boundedText(of: url) else { return false }
        return looksUnswitched(inLog: text, atLeast: atLeast)
    }

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
