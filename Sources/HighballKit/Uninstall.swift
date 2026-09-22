import Foundation

/// What removing a game means, which is not the same thing for every game.
///
/// Asked on r/macgaming as "how can i uninstall the game? couldn't find the button to do it"
/// (highball#185). Before this there was no answer on a game's page at all: Steam games came out
/// through the Steam client, anything with its own installer through Wine's Add/Remove Programs
/// in the environment's settings, and everything else only by deleting the whole environment.
///
/// The rule that shapes this: a store's library is the store's to keep. Deleting a Steam game's
/// folder from underneath the client leaves Steam believing it is installed, and the next launch
/// repairs or redownloads it, so a Steam game is handed to Steam's own uninstall dialog and
/// Highball does not touch the files. The same goes for Epic through legendary.
public enum Uninstall {
    public enum Route: Equatable, Sendable {
        /// Hand it to the running Steam client (`steam://uninstall/<appid>`), which asks its own
        /// confirmation and does the removing.
        case steam(appID: Int)
        /// Legendary owns Epic installs, so it does the removing.
        case epic(appName: String)
        /// Wine's Add/Remove Programs, for a program that came with its own uninstaller.
        case windowsUninstaller
        /// Nothing can be run for it. The reason is shown to the person, who then decides.
        case none(reason: String)
    }

    /// The route for one library item. Pure, so the wording and the choice are tested without a
    /// Steam client, a prefix or a network.
    public static func route(for item: LibraryItem) -> Route {
        switch item.source {
        case .steam:
            guard let appID = item.steamAppID else {
                return .none(reason: "Highball does not know this game's Steam id, so Steam cannot be asked to remove it.")
            }
            return .steam(appID: appID)
        case .epic:
            guard let name = item.epicAppName else {
                return .none(reason: "Highball does not know this game's Epic id, so the Epic tools cannot be asked to remove it.")
            }
            return .epic(appName: name)
        case .pin:
            return .windowsUninstaller
        }
    }

    /// The question asked before anything happens. It names the game, says who does the removing,
    /// and says how much space comes back when that is known, because "are you sure" without a
    /// figure is a question nobody can answer.
    public static func confirmation(title: String, route: Route, sizeOnDisk: Int64) -> String {
        let size = sizeOnDisk > 0 ? " That frees \(ByteCountFormatter.string(fromByteCount: sizeOnDisk, countStyle: .file))." : ""
        switch route {
        case .steam:
            return "Remove \(title)? Steam does the uninstalling and asks you to confirm in its own window, so its library stays right.\(size)"
        case .epic:
            return "Remove \(title)? The Epic tools do the uninstalling, so their library stays right.\(size)"
        case .windowsUninstaller:
            return "Remove \(title)? Highball opens Windows' Add or Remove Programs in this environment, where you pick it from the list. A game with no uninstaller of its own will not be in that list, and then the only way to remove it is to delete the environment."
        case let .none(reason):
            return reason
        }
    }

    /// True when the route can actually do something, so a view can offer the button only then
    /// and never open a dialog whose only answer is "nothing happens".
    public static func isActionable(_ route: Route) -> Bool {
        if case .none = route { return false }
        return true
    }

    /// The argument handed to the Steam client. Its own dialog does the rest.
    public static func steamURL(appID: Int) -> String { "steam://uninstall/\(appID)" }
}
