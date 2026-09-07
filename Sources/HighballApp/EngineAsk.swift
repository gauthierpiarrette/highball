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
        return String(format: L("%@ is verified on the %@ engine, and its installer fails on this environment's Wine build. A new environment keeps your other programs where they are%@. Moving this environment re-runs the Windows setup and keeps everything installed."),
                      recipe.title, shortEngineName(manifest), download)
    }
}
