import Foundation

/// Turns raw Wine/recipe/Steam output lines into human progress ("Step 2 of 3 — Battle.net-Setup")
/// and surfaces recipe slow-hints. Pure string logic, kept in the Kit so it is testable and shared;
/// the app feeds it every log line (#31: nobody should have to read raw Wine output to know
/// whether an install is working, finished, or stuck).
public enum ProgressParser {
    /// Human stage line for a raw output line, or nil if the line carries no stage information.
    public static func stage(for line: String) -> String? {
        if let m = line.firstMatch(of: #/\[(?<r>[a-z0-9-]+)\] step (?<a>\d+)/(?<b>\d+)(?: — (?<d>.+))?/#) {
            if let d = m.d { return "Step \(m.a) of \(m.b) — \(d)" }
            return "Step \(m.a) of \(m.b)"
        }
        if line.contains("Downloading update (") {
            if let m = line.firstMatch(of: #/\((?<x>[\d,]+) of (?<y>[\d,]+) KB\)/#) {
                return "Steam is updating itself — \(m.x) of \(m.y) KB"
            }
            return "Steam is updating itself"
        }
        if line.contains("Extracting package") { return "Extracting the Steam client — this takes a few minutes" }
        if line.contains("Installing update") { return "Installing the Steam client update" }
        if line.contains("Update complete") { return "Steam update complete — launching" }
        if line.hasPrefix("downloaded ") { return "Downloaded \(line.dropFirst(11))" }
        if line.contains("wineboot") && line.contains("start") { return "Preparing the Windows environment" }
        return nil
    }

    /// The slow-expectation text from a recipe hint line ("[dotnet48] hint: takes 20–40 min…"),
    /// or nil for any other line.
    public static func hint(for line: String) -> String? {
        guard line.hasPrefix("["), let r = line.range(of: "] hint: ") else { return nil }
        return String(line[r.upperBound...])
    }
}
