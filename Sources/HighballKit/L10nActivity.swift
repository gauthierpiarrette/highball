import Foundation

extension L10n {
    /// Format only ProgressParser's known stage grammar at the display boundary.
    /// Keep the original stage in state so step counters and log parsing remain unchanged.
    public static func activityStage(_ english: String) -> String {
        if let m = english.wholeMatch(of: #/Step (?<a>\d+) of (?<b>\d+)(?: — (?<label>.+))?/#) {
            if let label = m.label {
                return format("Step %@ of %@ — %@", String(m.a), String(m.b), String(label))
            }
            return format("Step %@ of %@", String(m.a), String(m.b))
        }
        if let m = english.wholeMatch(of: #/Steam is updating itself — (?<a>[\d,]+) of (?<b>[\d,]+) KB/#) {
            return format("Steam is updating itself — %@ of %@ KB", String(m.a), String(m.b))
        }
        if english.hasPrefix("Downloaded ") {
            return format("Downloaded %@", String(english.dropFirst("Downloaded ".count)))
        }
        return translate(english)
    }
}
