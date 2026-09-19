import Foundation

/// Facts about this Mac that every report carries.
public enum Machine {
    public static func chip() -> String {
        (try? Shell.capture("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown chip"
    }
    public static func macOSVersion() -> String {
        (try? Shell.capture("/usr/bin/sw_vers", ["-productVersion"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }
}

/// A compatibility report for highball-db, prefilled from a finished session so "how did it go"
/// costs one click and a rating (UX plan §3.5: Highball asks when you finish, never before).
/// The rating is the player's to give; nothing here invents one.
public enum PlayReport {
    public static let template = "report.yml"

    /// The issue URL for highball-db's report form, its fields prefilled by id. Query items use
    /// the form's field ids, which GitHub reads into the matching inputs.
    public static func url(title: String, appid: Int?, renderer: String?, chip: String, macos: String,
                           engine: String, minutes: Int, version: String? = nil, settings: String? = nil) -> URL {
        var comps = URLComponents(string: "https://github.com/gauthierpiarrette/highball-db/issues/new")!
        var items = [URLQueryItem(name: "template", value: template),
                     URLQueryItem(name: "title", value: title)]
        if let appid { items.append(URLQueryItem(name: "steam_appid", value: String(appid))) }
        if let renderer { items.append(URLQueryItem(name: "renderer", value: renderer)) }
        if let version { items.append(URLQueryItem(name: "version", value: version)) }
        if let settings, !settings.isEmpty { items.append(URLQueryItem(name: "settings", value: settings)) }
        items += [URLQueryItem(name: "chip", value: chip),
                  URLQueryItem(name: "macos", value: macos),
                  URLQueryItem(name: "engine", value: engine),
                  URLQueryItem(name: "notes", value: "Played for \(minutes) min through Highball.")]
        comps.queryItems = items
        return comps.url!
    }

    /// The settings that shaped the session, one per line, for the form's "Environment settings"
    /// field: the environment's mode, sync, Windows version and scale, then everything set away
    /// from its default (HUD, frame cap, frame generation, DLL overrides, extra variables, per-app
    /// DXVK options, recipes) and the program's own mode, arguments and variables when it has
    /// them. Defaults stay out so a reader sees what was chosen (highball#159 asked for every
    /// setting; a setting at its default says nothing about the run).
    public static func settingsSummary(_ s: BottleSettings, pin: Pin? = nil) -> String {
        var lines = ["mode \(s.renderer.rawValue), sync \(s.sync.rawValue), Windows \(s.windowsVersion.rawValue), scale \(s.dpiScale) dpi"]
        if s.metalHUD { lines.append("Metal HUD on") }
        if s.dxvkAsync { lines.append("DXVK async shader compilation on") }
        if s.advertiseAVX { lines.append("AVX advertised") }
        if s.fpsCap > 0 { lines.append("frame cap \(s.fpsCap)") }
        if s.frameGen > 1 {
            var fg = "frame generation \(s.frameGen)x"
            if s.frameGenAdaptive { fg += ", adaptive" }
            if s.frameGenFlowScale != 100 { fg += ", flow \(s.frameGenFlowScale)%" }
            if s.frameGenPerformance { fg += ", performance" }
            if !s.frameGenForceVsync { fg += ", vsync off" }
            lines.append(fg)
        }
        if !s.commandIsControl { lines.append("Command keys left as Alt") }
        if !s.dllOverrides.isEmpty { lines.append("DLL overrides \(s.dllOverrides)") }
        for (k, v) in s.environment.sorted(by: { $0.key < $1.key }) { lines.append("\(k)=\(v)") }
        for (exe, opts) in s.dxvkAppConfig.sorted(by: { $0.key < $1.key }) {
            lines.append("dxvk.conf [\(exe)] " + opts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        if !s.recipes.isEmpty { lines.append("recipes \(s.recipes.joined(separator: ", "))") }
        if let pin {
            if let r = pin.renderer { lines.append("program mode \(r.rawValue)") }
            if !pin.arguments.isEmpty { lines.append("program arguments \(pin.arguments.joined(separator: " "))") }
            for (k, v) in pin.environment.sorted(by: { $0.key < $1.key }) { lines.append("program \(k)=\(v)") }
        }
        return lines.joined(separator: "\n")
    }
}
