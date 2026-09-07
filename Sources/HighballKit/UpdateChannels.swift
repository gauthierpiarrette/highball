import Foundation

/// Which Sparkle channels an install may see. Stable is the unnamed channel every install gets;
/// "beta" carries each release for a day or two before promotion. The rule is a function so a
/// test pins it: a wrong answer here would either hide betas from testers or ship betas to everyone.
public enum UpdateChannels {
    public static let beta = "beta"
    /// The UserDefaults key behind Settings' "Get beta builds".
    public static let betaDefaultsKey = "betaUpdates"

    public static func allowed(beta: Bool) -> Set<String> {
        beta ? [Self.beta] : []
    }
}
