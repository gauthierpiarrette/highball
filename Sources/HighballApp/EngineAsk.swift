import Foundation
import HighballKit

// MARK: - An engine a recipe needs (#60)

extension GamePageCopy {
    /// "Wine 11.0 (CrossOver 26.3 tree, …) + DXMT …" → "Wine 11.0".
    static func shortEngineName(_ m: EngineManifest) -> String {
        String(m.displayName.prefix { $0 != "(" && $0 != "+" }).trimmingCharacters(in: .whitespaces)
    }

    static func downloadSize(_ m: EngineManifest) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(m.components.values.compactMap(\.size).reduce(0, +)), countStyle: .file)
    }

    static func engineAsk(recipe: HighballKit.Recipe, manifest: EngineManifest, installed: Bool) -> String {
        let download = installed ? "" : String(format: L(", after a download of about %@"), downloadSize(manifest))
        return String(format: L("%@ is verified on the %@ engine, and this environment is not on it. Moving this environment switches it there%@ and keeps everything installed; the Windows setup re-runs when needed, a minute or two. A new environment keeps your other programs where they are and starts empty, so the game has to be installed again."),
                      recipe.title, shortEngineName(manifest), download)
    }
}
