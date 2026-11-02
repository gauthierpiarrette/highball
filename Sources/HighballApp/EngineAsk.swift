import Foundation
import HighballKit

// MARK: - An engine a recipe needs (#60)

extension GamePageCopy {
    /// "Wine 11.0 (CrossOver 26.3 tree, …) + DXMT …" → "Wine 11.0".
    static func shortEngineName(_ m: EngineManifest) -> String {
        String(m.displayName.prefix { $0 != "(" && $0 != "+" }).trimmingCharacters(in: .whitespaces)
    }

    static func downloadSize(_ m: EngineManifest) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(m.downloadBytes), countStyle: .file)
    }

    /// The fix names an engine this build does not ship: the database moved ahead of the app.
    static func updateAsk(recipe: HighballKit.Recipe, engineID: String, canPlay: Bool) -> String {
        let play = canPlay ? " " + L("You can also play without the fix, as before.") : ""
        return String(format: L("%@'s fix runs on the %@ engine, and this version of Highball does not ship it yet. Check for Updates gets the version that does.%@"),
                      recipe.title, engineID, play)
    }

    /// `others` is how many other programs the environment has installed (Steam games and added
    /// programs): moving the environment moves them all onto the engine, which a player found out
    /// the hard way when an old revision could not show Steam's window (highball#262).
    /// `existing` names an environment already on that engine and whether the game is installed
    /// in it; the ask then offers it first (highball-db#318).
    /// `canMove` is false when the environment's engine is of another architecture than the
    /// recipe's (EngineStore.sameArch): only a new environment is offered then.
    /// `carriesGame` is true when the game installed in this environment can come along to a new one as an APFS
    /// clone (SteamGameCarryOver): no second download, no extra disk. `memoryMB` is this Mac's memory, checked
    /// against the recipe's minMemoryGB.
    static func engineAsk(recipe: HighballKit.Recipe, manifest: EngineManifest, installed: Bool, others: Int,
                          existing: (name: String, holdsGame: Bool)? = nil, canMove: Bool = true,
                          carriesGame: Bool = false, memoryMB: Int = Machine.memoryMB) -> String {
        guard let existing else {
            guard canMove else {
                return engineAskOtherArch(recipe: recipe, manifest: manifest, installed: installed, carriesGame: carriesGame)
                    + memoryNote(recipe: recipe, memoryMB: memoryMB)
            }
            return engineAskBody(recipe: recipe, manifest: manifest, installed: installed, others: others)
                + memoryNote(recipe: recipe, memoryMB: memoryMB)
        }
        return (existing.holdsGame
            ? String(format: L("'%@' is already on the %@ engine and has the game installed, so it plays there. This environment stays as it is."), existing.name, shortEngineName(manifest))
            : carriesGame
            ? String(format: L("'%@' is already on the %@ engine. Using it brings the game installed here along, without a new download or extra disk space, adds what it needs, and this environment stays as it is."), existing.name, shortEngineName(manifest))
            : String(format: L("'%@' is already on the %@ engine. Using it installs the game there, with what it needs, and this environment stays as it is."), existing.name, shortEngineName(manifest)))
            + memoryNote(recipe: recipe, memoryMB: memoryMB)
    }

    private static func engineAskOtherArch(recipe: HighballKit.Recipe, manifest: EngineManifest, installed: Bool,
                                           carriesGame: Bool) -> String {
        let download = installed ? "" : String(format: L(", after a download of about %@"), downloadSize(manifest))
        if carriesGame {
            let text = manifest.isNativeARM64
                ? L("%@ is verified on the %@ engine, which runs natively on Apple silicon. This environment's engine runs through Rosetta, so the environment cannot move to it. A new environment gets a Steam of its own%@, and the game installed here comes along without a new download or extra disk space. This environment stays as it is.")
                : L("%@ is verified on the %@ engine, which runs through Rosetta. This environment's engine runs natively on Apple silicon, so the environment cannot move to it. A new environment gets a Steam of its own%@, and the game installed here comes along without a new download or extra disk space. This environment stays as it is.")
            return String(format: text, recipe.title, shortEngineName(manifest), download)
        }
        let text = manifest.isNativeARM64
            ? L("%@ is verified on the %@ engine, which runs natively on Apple silicon. This environment's engine runs through Rosetta, so the environment cannot move to it. A new environment starts empty%@, and the game has to be installed again.")
            : L("%@ is verified on the %@ engine, which runs through Rosetta. This environment's engine runs natively on Apple silicon, so the environment cannot move to it. A new environment starts empty%@, and the game has to be installed again.")
        return String(format: text, recipe.title, shortEngineName(manifest), download)
    }

    /// A recipe pinned to a preview engine this Mac does not see yet: Play asks before anything changes. Before
    /// 0.10.19 Play launched such a game on the current engine as if the recipe did not exist, which for Microsoft
    /// Flight Simulator 2024 was a Rosetta engine it cannot start on.
    static func previewAsk(recipe: HighballKit.Recipe, manifest: EngineManifest, memoryMB: Int = Machine.memoryMB) -> String {
        let text = manifest.isNativeARM64
            ? L("%@ is verified on the %@ engine, which runs natively on Apple silicon and is still in preview: the game plays, with the rough edges its page lists. Highball offers that engine for this game, sets it up in an environment of its own, and leaves this one as it is.")
            : L("%@ is verified on the %@ engine, which is still in preview: the game plays, with the rough edges its page lists. Highball offers that engine for this game, sets it up in an environment of its own, and leaves this one as it is.")
        let route = recipe.previewRouteNote.flatMap { $0.isEmpty ? nil : " " + $0 } ?? ""
        return String(format: text, recipe.title, shortEngineName(manifest)) + route + memoryNote(recipe: recipe, memoryMB: memoryMB)
    }

    /// "r5" for arm64-wine11.18-r5, the id itself when it carries no revision.
    static func revisionName(_ m: EngineManifest) -> String {
        EngineManifest.revision(of: m.id).map { "r\($0)" } ?? m.id
    }

    /// An environment on an earlier revision of the preview line its game's recipe pins (AppState.pendingPreviewMove).
    static func previewMoveAsk(recipe: HighballKit.Recipe, current: EngineManifest, manifest: EngineManifest, installed: Bool) -> String {
        let download = installed ? "" : String(format: L(", after a download of about %@"), downloadSize(manifest))
        return String(format: L("%@ is now verified on %@ of its preview engine, and this environment still runs %@. Moving the environment switches it there%@ and keeps the game and everything else installed. The Windows setup re-runs, which takes a minute or two. Highball asks this once, and the environment's Engine setting can move it later."),
                      recipe.title, revisionName(manifest), revisionName(current), download)
    }

    /// A game whose recipe's engine needs a newer macOS than this Mac runs (AppState.pendingMacOS). `current` is
    /// "major.minor.patch", shown without a patch of 0.
    static func macOSAsk(recipe: HighballKit.Recipe, floor: String, current: String) -> String {
        let shown = current.hasSuffix(".0") ? String(current.dropLast(2)) : current
        return String(format: L("%@'s fix runs on an engine that needs macOS %@ or later, and this Mac runs macOS %@. Once macOS is updated, Play sets it up. You can also play without the fix, as before."),
                      recipe.title, floor, shown)
    }

    /// One sentence when the recipe names a memory floor this Mac is under, empty otherwise. The floor is the memory
    /// the game was tested with, so the sentence says that rather than a hard requirement: smaller Macs are untested,
    /// not ruled out (2026-10-19).
    static func memoryNote(recipe: HighballKit.Recipe, memoryMB: Int) -> String {
        guard let short = recipe.memoryShortfall(memoryMB: memoryMB) else { return "" }
        return " " + String(format: L("It was tested on Macs with %d GB of memory and this Mac has %d GB, so it may not run well here."),
                            short.needGB, short.haveGB)
    }

    private static func engineAskBody(recipe: HighballKit.Recipe, manifest: EngineManifest, installed: Bool, others: Int) -> String {
        let download = installed ? "" : String(format: L(", after a download of about %@"), downloadSize(manifest))
        if others == 0 {
            return String(format: L("%@ is verified on the %@ engine, and this environment is not on it. Moving this environment switches it there%@ and keeps everything installed; the Windows setup re-runs when needed, a minute or two. A new environment starts empty, so the game has to be installed again."),
                          recipe.title, shortEngineName(manifest), download)
        }
        let programs = others == 1 ? L("the other program installed here") : String(format: L("the %d other programs installed here"), others)
        return String(format: L("%@ is verified on the %@ engine, and this environment is not on it. A new environment keeps %@ where they are and starts empty, so the game has to be installed again. Moving this environment switches it there%@ and keeps everything installed, but %@ then run on that engine too, which suits some games and not others; the Windows setup re-runs when needed, a minute or two."),
                      recipe.title, shortEngineName(manifest), programs, download, programs)
    }
}
