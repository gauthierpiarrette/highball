import Foundation

/// The sentences on a game's page (UX plan §3.5). Facts stated, gaps named, nothing computed
/// that was not measured: "verified on an M4 Pro" and "your Mac is an M1 Pro", never
/// "verified on a Mac like yours".
public enum GamePageCopy {
    public struct Verdict: Equatable {
        public var headline: String
        public var detail: String?
    }

    /// The verdict sentence for an entry (nil: no row at all), given the reader's chip.
    public static func verdict(_ entry: GameDBEntry?, myChip: String, today: Date = Date()) -> Verdict {
        let mine = shortChip(myChip)
        guard let entry else {
            return Verdict(headline: "Nobody has tested this on an \(mine) yet.",
                           detail: "Play, and Highball will ask how it went when you finish.")
        }
        switch entry.status {
        case "blocked-anticheat":
            let name = entry.anticheat?.names.first ?? "its anti-cheat"
            return Verdict(headline: "Can't run: \(name).",
                           detail: entry.anticheat?.note ?? "Its anti-cheat does not run on macOS.")
        case "verified-local":
            let chip = entry.verified?.chip.map(shortChip)
            var head = chip.map { "Verified on an \($0)." } ?? "Verified on this project's own Mac."
            if chip == mine { head = "Verified on an \(mine), the same chip as yours." }
            var parts: [String] = []
            if let fps = entry.verified?.fps {
                parts.append(fps.hasSuffix("fps") ? fps : "\(fps) frames per second")
            }
            if let os = entry.verified?.macos { parts.append("on macOS \(os)") }
            var detail = parts.isEmpty ? "" : sentenceCase(parts.joined(separator: " "))
            if let when = freshness(entry.lastVerified, today: today) {
                detail += detail.isEmpty ? "Last confirmed \(when)." : ", last confirmed \(when)."
            } else if !detail.isEmpty { detail += "." }
            if let chip, chip != mine { detail += (detail.isEmpty ? "" : " ") + "Your Mac is an \(mine)." }
            return Verdict(headline: head, detail: detail.isEmpty ? nil : detail)
        case "reported-upstream":
            return Verdict(headline: "Reported working upstream.",
                           detail: "Named in the renderer's release notes as working; not verified here yet. Your Mac is an \(mine).")
        default:
            return Verdict(headline: "Reported by players.",
                           detail: "Not verified by this project yet. Your Mac is an \(mine).")
        }
    }

    /// One line of "when you press Play, Highball will".
    public struct WillDo: Equatable {
        public var text: String
        public var cost: String?
        public var done: Bool
        public init(text: String, cost: String? = nil, done: Bool = false) { self.text = text; self.cost = cost; self.done = done }
    }

    /// What Play applies, in order, from the row and the fix recipe. `applied` means the recipe
    /// already ran in this environment, so its steps read as done.
    public static func willDo(_ entry: GameDBEntry?, recipe: Recipe?, applied: Bool,
                              bottleRenderer: Renderer, osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> [WillDo] {
        var items: [WillDo] = []
        if let wanted = entry?.effectiveRenderer(osMajor: osMajor) {
            items.append(WillDo(text: wanted == bottleRenderer
                                ? "Use \(plainName(wanted)), the way it was verified"
                                : "Use \(plainName(wanted)) for this game, the way it was verified, instead of the environment's \(wanted == bottleRenderer ? "" : plainName(bottleRenderer))"))
        } else {
            items.append(WillDo(text: "Use \(plainName(bottleRenderer)), the environment's setting; no verdict names a better one"))
        }
        if let args = entry?.effectiveLaunchArgs(osMajor: osMajor), !args.isEmpty {
            items.append(WillDo(text: "Start it with \(args.joined(separator: " "))"))
        }
        if let recipe {
            for step in recipe.steps {
                guard let text = describe(step) else { continue }
                items.append(WillDo(text: text, cost: applied ? nil : step.slowHint, done: applied))
            }
        }
        return items
    }

    // MARK: helpers

    public static func plainName(_ r: Renderer) -> String {
        switch r {
        case .dxmt: return "DXMT (DirectX 11 on Metal)"
        case .d3dmetal: return "Apple's DirectX 12 support"
        case .dxvk: return "DXVK (Vulkan on Metal)"
        case .wined3d: return "Wine's own Direct3D"
        }
    }

    /// "Apple M1 Pro" -> "M1 Pro"; anything else unchanged.
    public static func shortChip(_ chip: String) -> String {
        let t = chip.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("Apple ") ? String(t.dropFirst(6)) : t
    }

    /// "today", "yesterday", "12 days ago", or "on 2026-08-25" past two months.
    static func freshness(_ ymd: String?, today: Date) -> String? {
        guard let ymd else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: ymd) else { return nil }
        let days = Int(today.timeIntervalSince(d) / 86_400)
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2...60: return "\(days) days ago"
        default: return "on \(ymd)"
        }
    }

    static func sentenceCase(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    static func describe(_ step: Recipe.Step) -> String? {
        switch step {
        case let .installer(_, _, _, label, _, _): return "Install \(label)"
        case let .winetricks(verbs, _): return "Install \(verbs.joined(separator: ", "))"
        case let .registry(_, name, _, _): return "Set the Windows registry value \(name)"
        case let .environment(name, _): return "Set \(name) for this game"
        case let .renderer(r): return "Switch the environment's graphics mode to \(plainName(r))"
        case let .sync(m): return "Set the environment's sync mode to \(m.rawValue)"
        case let .winver(v): return "Report Windows \(v.rawValue) to the game"
        case let .file(path, _): return "Write \(URL(fileURLWithPath: path).lastPathComponent)"
        case .pin: return nil
        case let .note(text): return text
        case let .dxvkConfig(exe, _): return "Configure DXVK for \(exe)"
        }
    }
}
