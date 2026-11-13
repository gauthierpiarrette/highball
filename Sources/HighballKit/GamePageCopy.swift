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
            return Verdict(headline: L10n.format("Nobody has tested this on an %@ yet.", String(describing: mine)),
                           detail: L10n.translate("Nothing in the compatibility database for it yet. You would be the first to report it."))
        }
        switch entry.status {
        case "blocked-anticheat":
            let name = entry.anticheat?.names.first ?? L10n.translate("its anti-cheat")
            return Verdict(headline: L10n.format("Can't run: %@.", String(describing: name)),
                           detail: entry.anticheat?.note ?? L10n.translate("Its anti-cheat does not run on macOS."))
        case "blocked-publisher":
            return Verdict(headline: L10n.translate("Can't run: its publisher blocks macOS."),
                           detail: L10n.translate("The game stops itself when it finds macOS, whatever the engine or graphics mode."))
        case "verified-local":
            let chip = entry.verified?.chip.map(shortChip)
            var head = chip.map { L10n.format("Verified on an %@.", String(describing: $0)) } ?? L10n.translate("Verified on this project's own Mac.")
            if chip == mine { head = L10n.format("Verified on an %@, the same chip as yours.", String(describing: mine)) }
            var parts: [String] = []
            if let fps = entry.verified?.fps, let phrase = fpsPhrase(fps) {
                parts.append(phrase)
            }
            if let os = entry.verified?.macos { parts.append(L10n.format("on macOS %@", String(describing: os))) }
            var detail = parts.isEmpty ? "" : sentenceCase(parts.joined(separator: " "))
            if let when = freshness(entry.lastVerified, today: today) {
                detail += detail.isEmpty ? L10n.format("Last confirmed %@.", String(describing: when)) : L10n.format(", last confirmed %@.", String(describing: when))
            } else if !detail.isEmpty { detail += "." }
            if let chip, chip != mine { detail += (detail.isEmpty ? "" : " ") + L10n.format("Your Mac is an %@.", String(describing: mine)) }
            return Verdict(headline: head, detail: detail.isEmpty ? nil : detail)
        case "reported-upstream":
            return Verdict(headline: L10n.translate("Reported working upstream."),
                           detail: L10n.format("Named in the renderer's release notes as working; not verified here yet. Your Mac is an %@.", String(describing: mine)))
        default:
            return Verdict(headline: L10n.translate("Reported by players."),
                           detail: L10n.format("Not verified by this project yet. Your Mac is an %@.", String(describing: mine)))
        }
    }

    /// The card for a game with a native Mac build on Steam. The Windows build stays available,
    /// as a secondary action: it can still be the one someone wants (a port that lags behind,
    /// an Intel-only one, mods).
    public struct MacBuild: Equatable {
        public var headline: String
        public var detail: String
        /// The row's note: the build's own requirements ("macOS 12 and M1 or later").
        public var requirements: String?
        public var yourMac: String
        public var source: String
    }

    public static func macBuild(_ build: MacSteamBuild?, entry: GameDBEntry?, myChip: String, macOS: String) -> MacBuild? {
        guard let build else { return nil }
        let installed = build == .installed
        let source = switch build {
        case .installed: L10n.translate("Steam for Mac lists it as installed.")
        case .inDatabase: L10n.translate("From the compatibility database.")
        case .inAppInfo: L10n.translate("Steam's own data marks a Mac build that runs on current macOS.")
        case .onStore: L10n.translate("Steam's store page lists macOS for it.")
        }
        return MacBuild(
            headline: installed ? L10n.translate("Installed in Steam for Mac.") : L10n.translate("There is a native Mac build on Steam."),
            detail: installed
                ? L10n.translate("Play starts the Mac build through Steam for Mac, with no Windows layer in between.")
                : L10n.translate("It will beat running the Windows version through any compatibility layer, and your Steam purchase already includes it."),
            requirements: entry?.nativeMac?.available == true ? entry?.nativeMac?.note : nil,
            yourMac: L10n.format("Your Mac is an %@ on macOS %@.", String(describing: shortChip(myChip)), String(describing: macOS)),
            source: source)
    }

    /// Steam lists a Mac version that is 32-bit, which no macOS since Catalina runs, so the page
    /// offers the Windows version alone. Said once, so the missing Mac button is not a mystery
    /// (udance4ever's suggestion on highball#316). A database row about the Mac version decides
    /// instead, as it does for the Mac card.
    public static func outdatedMacBuild(appInfo: MacAppInfoBuild?, entry: GameDBEntry?) -> String? {
        guard appInfo == .only32Bit, entry?.nativeMac == nil else { return nil }
        return L10n.translate("Steam also has a Mac version of this game, but it is 32-bit and macOS has not run those since Catalina, so Highball installs the Windows version.")
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
    /// `needsDirect3D12`: the program only has Direct3D 12 (`ProgramNeeds.wantsDirect3D12`), so a
    /// mode without it gives way at Play (`Renderer.direct3D12TakeOver`) and the plan says so.
    public static func willDo(_ entry: GameDBEntry?, recipe: Recipe?, applied: Bool,
                              bottleRenderer: Renderer, explicit: Bool = false, gameOverride: Renderer? = nil,
                              needsDirect3D12: Bool = false,
                              osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> [WillDo] {
        var items: [WillDo] = []
        let rowMode = entry?.effectiveRenderer(osMajor: osMajor)
        let direct3D12Mode = (rowMode?.servesDirect3D12 == true ? rowMode : nil) ?? .d3dmetal
        let givesWay = needsDirect3D12 && !bottleRenderer.servesDirect3D12 && (explicit || rowMode == nil)
        if entry?.nativeVulkan == true {
            items.append(WillDo(text: L10n.translate("Let it draw with Vulkan directly; the graphics mode does not apply to this game")))
        } else if let gameOverride {
            items.append(WillDo(text: L10n.format("Use %@ for this game (set by you); the environment stays on %@", String(describing: plainName(gameOverride)), String(describing: plainName(bottleRenderer)))))
        } else if givesWay {
            // The launch switches (Renderer.direct3D12TakeOver); the plan must not promise the
            // environment's mode for a game that cannot run in it.
            items.append(WillDo(text: explicit
                                ? L10n.format("Use %@ for this game: it only has DirectX 12, which %@, your environment's setting, does not have. The environment keeps %@ for everything else", String(describing: plainName(direct3D12Mode)), String(describing: plainName(bottleRenderer)), String(describing: plainName(bottleRenderer)))
                                : L10n.format("Use %@ for this game: it only has DirectX 12, which the environment's %@ does not have", String(describing: plainName(direct3D12Mode)), String(describing: plainName(bottleRenderer)))))
        } else if explicit {
            if let wanted = entry?.effectiveRenderer(osMajor: osMajor), wanted != bottleRenderer {
                items.append(WillDo(text: L10n.format("Use %@, your environment's setting. The database asks for %@, and an environment's own setting wins", String(describing: plainName(bottleRenderer)), String(describing: plainName(wanted)))))
            } else {
                items.append(WillDo(text: L10n.format("Use %@, the environment's setting (set by you)", String(describing: plainName(bottleRenderer)))))
            }
        } else if let wanted = entry?.effectiveRenderer(osMajor: osMajor) {
            items.append(WillDo(text: wanted == bottleRenderer
                                ? L10n.format("Use %@, the way it was verified", String(describing: plainName(wanted)))
                                : L10n.format("Use %@ for this game, the way it was verified, instead of the environment's %@", String(describing: plainName(wanted)), String(describing: wanted == bottleRenderer ? "" : plainName(bottleRenderer)))))
        } else {
            items.append(WillDo(text: L10n.format("Use %@, the environment's setting; no verdict names a better one", String(describing: plainName(bottleRenderer)))))
        }
        if let args = entry?.effectiveLaunchArgs(osMajor: osMajor), !args.isEmpty {
            items.append(WillDo(text: L10n.format("Start it with %@", String(describing: args.joined(separator: " ")))))
        }
        if let recipe, recipe.isOptIn {
            // Play does not touch an opt-in fix; the page says so rather than listing steps
            // Play will not take.
            items.append(WillDo(text: applied
                                ? L10n.format("Keep the %@ fix you applied under Game settings", String(describing: recipe.title))
                                : L10n.format("Leave the optional %@ fix alone; it is under Game settings for when the notes say your Mac needs it", String(describing: recipe.title)),
                                done: applied))
        } else if let recipe {
            // A route's list of switches says nothing to a reader as 28 lines (Forza Horizon 6's emulator switches).
            let variables = recipe.steps.filter { if case .environment = $0 { return true } else { return false } }.count
            if variables > 6 {
                items.append(WillDo(text: L10n.format("Set %@ emulator and graphics variables for this game", String(describing: variables)), done: applied))
            }
            for step in recipe.steps {
                if variables > 6, case .environment = step { continue }
                guard let text = describe(step) else { continue }
                items.append(WillDo(text: text, cost: applied ? nil : step.slowHint, done: applied))
            }
        }
        return items
    }

    /// The row's renderer when only the environment's explicit setting keeps it from applying and
    /// no per-game choice exists yet. The game page offers it for this game alone, so the reader
    /// is never left with a plan that names two graphics modes (2026-09-11 walkthrough).
    public static func rowRendererHeldBack(_ entry: GameDBEntry?, bottleRenderer: Renderer, explicit: Bool, gameOverride: Renderer?,
                                           needsDirect3D12: Bool = false,
                                           osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> Renderer? {
        guard explicit, gameOverride == nil, entry?.nativeVulkan != true,
              let wanted = entry?.effectiveRenderer(osMajor: osMajor), wanted != bottleRenderer else { return nil }
        // Nothing is held back from a program that only has Direct3D 12: Play already gives it
        // the row's mode when the environment's has no Direct3D 12 (Renderer.direct3D12TakeOver).
        if needsDirect3D12, !bottleRenderer.servesDirect3D12, wanted.servesDirect3D12 { return nil }
        return wanted
    }

    /// The row's fps field is a figure followed by where it was read: "about 34 in the prologue
    /// ride at 1280x720". The sentence keeps both, puts "frames per second" after the figure, and
    /// stops at the first full stop so the verdict stays one sentence. A field that starts with
    /// no figure ("menu renders, DXVK") is used as it is; a paragraph stitched in by mistake is
    /// cut the same way (2026-09-11, Assetto Corsa).
    public static func fpsPhrase(_ fps: String) -> String? {
        var t = fps.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stop = t.range(of: ". ") { t = String(t[..<stop.lowerBound]) }
        if t.hasSuffix(".") { t.removeLast() }
        guard !t.isEmpty else { return nil }
        let figure = "^(?i:about )?[0-9]+(?:\\.[0-9]+)?(?:\\s*(?:-|–|to)\\s*[0-9]+(?:\\.[0-9]+)?)?"
        guard let r = t.range(of: figure, options: .regularExpression) else { return t }
        let rest = String(t[r.upperBound...])
        if rest.lowercased().hasPrefix(" fps") { return t }
        return String(t[r]) + L10n.translate(" frames per second") + rest
    }

    // MARK: helpers

    public static func plainName(_ r: Renderer) -> String {
        switch r {
        case .dxmt: return L10n.translate("DXMT (DirectX 11 on Metal)")
        case .d3dmetal: return L10n.translate("Apple's DirectX 12 support")
        case .dxvk: return L10n.translate("DXVK (Vulkan on Metal)")
        case .wined3d: return L10n.translate("Wine's own Direct3D")
        case .vkd3d: return L10n.translate("vkd3d-proton (DirectX 12 through Vulkan)")
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
        case ..<1: return L10n.translate("today")
        case 1: return L10n.translate("yesterday")
        case 2...60: return L10n.format("%@ days ago", String(describing: days))
        default: return L10n.format("on %@", String(describing: ymd))
        }
    }

    static func sentenceCase(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    static func describe(_ step: Recipe.Step) -> String? {
        switch step {
        case let .installer(_, _, _, label, _, _): return L10n.format("Install %@", String(describing: label))
        case let .winetricks(verbs, _): return L10n.format("Install %@", String(describing: verbs.joined(separator: ", ")))
        case let .registry(_, name, _, _): return L10n.format("Set the Windows registry value %@", String(describing: name))
        case let .environment(name, _): return L10n.format("Set %@ for this game", String(describing: name))
        case let .renderer(r): return L10n.format("Switch the environment's graphics mode to %@", String(describing: plainName(r)))
        case let .sync(m): return L10n.format("Set the environment's sync mode to %@", String(describing: m.rawValue))
        case let .winver(v): return L10n.format("Report Windows %@ to the game", String(describing: v.rawValue))
        case let .file(path, _): return L10n.format("Write %@", String(describing: URL(fileURLWithPath: path).lastPathComponent))
        case let .copy(from, _, _): return L10n.format("Give the game its own %@ from the engine", String(describing: URL(fileURLWithPath: from).lastPathComponent))
        case .pin: return nil
        case let .note(text): return text
        case let .dllOverride(v): return L10n.format("Set the Windows library override %@", String(describing: v))
        case let .frameCap(n): return L10n.format("Cap the frame rate at %@", String(describing: n))
        case let .dxvkConfig(exe, _): return L10n.format("Configure DXVK for %@", String(describing: exe))
        }
    }
}

extension GamePageCopy {
    /// The consequence sentence of the D3DMetal ask, from the row: "will not start" only when
    /// no other renderer is recorded as working, "runs faster with it" when one is.
    public static func d3dMetalAsk(title: String, entry: GameDBEntry?) -> String {
        // Asked because the environment (or a pinned program) is set to D3DMetal, not because
        // the row needs it (#61): say where the setting came from and that the default runs.
        guard entry?.effectiveRenderer() == .d3dmetal else {
            return L10n.format("The environment %@ runs in is set to D3DMetal, which needs Apple's licence accepted for its engine. Turning it on means accepting that licence, which allows non-commercial use; nothing downloads and nothing is sent to Apple. Playing with DXMT, Highball's default, works for most games.", String(describing: title))
        }
        let consequence = otherWorkingRenderer(entry).map {
            L10n.format("Without it, %@ still runs on %@, which was recorded as working, but slower.", String(describing: title), String(describing: plainName($0)))
        } ?? L10n.format("The database records no other graphics mode as working for %@, so without it Highball has nothing else to try.", String(describing: title))
        return L10n.format("Highball already includes it. Turning it on means accepting Apple's licence, which allows non-commercial use. %@ Nothing to download and nothing sent to Apple.", String(describing: consequence))
    }

    /// A graphics mode other than D3DMetal that the row recorded as working, if any.
    public static func otherWorkingRenderer(_ entry: GameDBEntry?) -> Renderer? {
        guard let results = entry?.rendererResults else { return nil }
        for key in ["dxmt", "vkd3d", "dxvk", "wined3d"] where results[key]?.verdict == "works" {
            if let r = Renderer(rawValue: key) { return r }
        }
        return nil
    }
}
