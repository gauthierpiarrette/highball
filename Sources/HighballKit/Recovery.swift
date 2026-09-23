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
        /// Download and unpack this engine again over the damaged copy.
        case reinstallEngine(String)
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
        case let .engineDamaged(engine, files):
            // The files came back as "not found" from inside Wine, so the loader's own words
            // ("could not load ...") are useless here: say where the files went and offer the
            // one thing that brings them back. The exclusion matters more than the download —
            // without it the fresh engine is quarantined again within the hour (#153).
            return Recovery(headline: "Files are missing from Highball's engine.",
                            meaning: "\(EngineIntegrity.list(files)) left engine \(engine) after it was installed, so no Windows program can start in it. Antivirus software quarantining Highball's folder is what this looks like from the inside: add ~/Library/Application Support/Highball to its exclusions first, then install the engine again.",
                            actionTitle: "Install the engine again", action: .reinstallEngine(engine))
        case .checksumMismatch:
            return Recovery(headline: "The download didn't arrive intact.",
                            meaning: "This is usually a network problem. Highball discards the damaged file and downloads it again.",
                            actionTitle: "Download again", action: .retry)
        // Before any other failed command, because this one is the environment rather than the
        // step: while the licence sits unaccepted, macOS refuses every Xcode-provided tool, and
        // winetricks' own closing line then names something unrelated ("wine cmd.exe ... returned
        // empty string"). highball#180 spent three rounds looking at downloads and SourceForge
        // before the reporter found it themselves. Retry is still the right button, because it is
        // the right one once they have accepted.
        case let .processFailed(_, _, output) where Self.xcodeLicenceUnaccepted(output):
            return Recovery(headline: "Xcode's licence has not been accepted on this Mac.",
                            meaning: "Until it is, the developer tools this step needs refuse to run, so it stops partway and says something unrelated. Open Terminal, run sudo xcodebuild -license, read it through and accept it, then try again here.",
                            actionTitle: "Try again", action: .retry)
        case let .processFailed(command, _, _) where command.hasPrefix("wineboot"):
            return Recovery(headline: "The Windows environment didn't finish setting up.",
                            meaning: "Highball can run the setup again.",
                            actionTitle: "Repair", action: .repairBottle)
        case let .processFailed(command, _, output) where command.contains("winetricks"):
            // The command is "/bin/bash <winetricks> --unattended <verbs>": naming bash helps
            // nobody (highball#135 read "/bin/bash didn't finish" and offered a fresh download).
            let words = command.split(separator: " ").map(String.init)
            let verbs = words.drop(while: { $0 != "--unattended" }).dropFirst().joined(separator: " ")
            let what = verbs.isEmpty ? "The winetricks step" : "Installing \(verbs) with winetricks"
            // The reason is the script's own last line, and asking for it under Details cost
            // #135 two rounds with nothing pasted back. Say it up front.
            var meaning = "It downloads its files from the internet as it runs, and those servers refuse now and then, so trying again in a few minutes often works."
            // Where the whole run is, so a report can carry it: the newest winetricks file in the
            // logs folder, which Troubleshooting opens. Said before the script's own words, because
            // the reason stays the last thing anyone reads (highball#135).
            meaning += " The full output is in Highball's logs folder, in the newest file with winetricks in its name."
            if let reason = Self.winetricksReason(output) { meaning += " It said: \(reason)" }
            return Recovery(headline: "\(what) didn't finish.", meaning: meaning,
                            actionTitle: "Try again", action: .retry)
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


extension Recovery {
    /// macOS refuses every Xcode-provided command line tool until the licence has been accepted,
    /// and prints this one sentence when it does. It can land anywhere in a step's output rather
    /// than at the end, so it is matched across the whole of it: in highball#180 it appeared four
    /// times in the middle of a corefonts run whose last real line was about `%AppData%`.
    static func xcodeLicenceUnaccepted(_ output: String) -> Bool {
        output.contains("You have not agreed to the Xcode license agreements")
    }

    /// The last line of a winetricks run that says something, skipping its progress noise and
    /// the shell's own "exited with" footer. Nil when the output is empty.
    static func winetricksReason(_ output: String) -> String? {
        let noise = ["warning: taskset", "Executing", "------", "[mvk-", "fixme:", "exited with"]
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.last { line in
            !line.isEmpty && !noise.contains { line.hasPrefix($0) || line.contains($0) }
        }.map { String($0.prefix(200)) }
    }
}
