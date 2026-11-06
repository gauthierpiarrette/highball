import Foundation

/// When Highball closes a GOG or Epic Mac game opened outside it (Applications, the Dock,
/// Spotlight) and starts it again through Highball (AppState.macAppLaunched). Pure, so the tests
/// reach the choice the app makes.
public enum MacRelaunch {
    /// A launch this soon after Highball started the game is Highball's own.
    public static let ownLaunchWindow: TimeInterval = 15
    /// A game closed to start it again is not closed again this soon, so the watch never loops.
    public static let takenOverWindow: TimeInterval = 60
    /// Only an app opened this recently is closed: one running longer is being played.
    public static let freshLaunchWindow: TimeInterval = 8

    /// Whether to close a game just opened outside Highball: never while the game Highball
    /// started has not ended (an app from its folder then is its own, a launcher's hand-over or
    /// a helper, however late it opens), nor within `ownLaunchWindow` of Highball starting it, nor
    /// within `takenOverWindow` of closing it already. Only an app that is still running and
    /// opened within `freshLaunchWindow`, and only when Highball can start the game again right
    /// now: a busy Highball (a download holding the strip) would close it and start nothing.
    /// And only when Highball's start adds something the outside launch lacks (`highballAdds`:
    /// comet or the save sync for a GOG game, Epic's sign-in for an Epic one): without it,
    /// closing the game would only cost the player a restart.
    public static func shouldTakeOver(now: Date, gameRunning: Bool, startedAt: Date?, takenOverAt: Date?,
                                      appLaunchedAt: Date?, appTerminated: Bool, busy: Bool, canStart: Bool,
                                      highballAdds: Bool) -> Bool {
        if gameRunning { return false }
        if let startedAt, now.timeIntervalSince(startedAt) < ownLaunchWindow { return false }
        if let takenOverAt, now.timeIntervalSince(takenOverAt) < takenOverWindow { return false }
        guard !appTerminated, let appLaunchedAt, now.timeIntervalSince(appLaunchedAt) < freshLaunchWindow, !busy else { return false }
        return canStart && highballAdds
    }

    /// Whether an app at `bundle` is from a game's `folder`: the folder itself (a GOG build's
    /// .app) or anything inside it, never a sibling whose name only starts the same.
    public static func opens(bundle: String, from folder: String) -> Bool {
        bundle == folder || bundle.hasPrefix(folder + "/")
    }
}
