import Foundation

/// What a failure looks like on the primary surface: one sentence about what happened, one
/// about what it means, and at most one button that does the next thing (UX plan §3.6). Raw
/// output and exit codes never appear here; they stay behind a details view. A cause is named
/// only when the app actually detected it: a 60-second timeout is not "your connection dropped".
public struct Recovery: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Run the same operation again (installs, downloads, recipe steps).
        case retry
        /// Re-run the bottle's Windows setup.
        case repairBottle
        /// Nothing automatic; the details and a report are the next step.
        case none
    }
    public var headline: String
    public var meaning: String
    public var actionTitle: String?
    public var action: Action

    public init(headline: String, meaning: String, actionTitle: String? = nil, action: Action = .none) {
        self.headline = headline; self.meaning = meaning; self.actionTitle = actionTitle; self.action = action
    }

    /// The mapping from what actually failed to what the user sees. Unknown failures keep their
    /// own message as the headline so nothing is hidden, and get no button.
    public static func describe(_ error: Error) -> Recovery {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return Recovery(headline: "The download could not reach the server.",
                                meaning: "Highball keeps what it already received and continues from there.",
                                actionTitle: "Try again", action: .retry)
            case .timedOut:
                return Recovery(headline: "The download stopped waiting for data.",
                                meaning: "Highball keeps what it already received and continues from there.",
                                actionTitle: "Try again", action: .retry)
            default:
                return Recovery(headline: "The download stopped.",
                                meaning: "Highball keeps what it already received and continues from there.",
                                actionTitle: "Try again", action: .retry)
            }
        }
        guard let known = error as? HighballError else {
            return Recovery(headline: (error as NSError).localizedDescription, meaning: "")
        }
        switch known {
        case .checksumMismatch:
            return Recovery(headline: "The download didn't arrive intact.",
                            meaning: "This is usually a network problem. Highball discards the damaged file and downloads it again.",
                            actionTitle: "Download again", action: .retry)
        case let .processFailed(command, _, _) where command.hasPrefix("wineboot"):
            return Recovery(headline: "The Windows environment didn't finish setting up.",
                            meaning: "Highball can run the setup again.",
                            actionTitle: "Repair", action: .repairBottle)
        case let .processFailed(command, _, _):
            let name = command.split(separator: " ").first.map(String.init) ?? "The installer"
            return Recovery(headline: "\(name) didn't finish.",
                            meaning: "Highball can try again with a fresh copy.",
                            actionTitle: "Try again", action: .retry)
        case let .invalid(what) where what.contains("32-bit"):
            return Recovery(headline: "The Windows environment didn't finish setting up.",
                            meaning: "Its 32-bit half is missing, which most installers need. Highball can repair it.",
                            actionTitle: "Repair", action: .repairBottle)
        case let .missing(what):
            return Recovery(headline: "Something Highball needs is missing.", meaning: what)
        case let .invalid(what), let .failed(what):
            return Recovery(headline: what, meaning: "")
        }
    }
}
