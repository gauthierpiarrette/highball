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
                           engine: String, minutes: Int) -> URL {
        var comps = URLComponents(string: "https://github.com/gauthierpiarrette/highball-db/issues/new")!
        var items = [URLQueryItem(name: "template", value: template),
                     URLQueryItem(name: "title", value: title)]
        if let appid { items.append(URLQueryItem(name: "steam_appid", value: String(appid))) }
        if let renderer { items.append(URLQueryItem(name: "renderer", value: renderer)) }
        items += [URLQueryItem(name: "chip", value: chip),
                  URLQueryItem(name: "macos", value: macos),
                  URLQueryItem(name: "engine", value: engine),
                  URLQueryItem(name: "notes", value: "Played for \(minutes) min through Highball.")]
        comps.queryItems = items
        return comps.url!
    }
}
