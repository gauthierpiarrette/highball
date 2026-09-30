import SwiftUI
import AppKit

/// Reopens the main surface for menu commands, incoming files and Dock clicks.
@MainActor
enum MainWindow {
    /// Set from a view's onAppear: `{ openWindow(id: "main") }`.
    static var opener: (() -> Void)?

    static func isMain(_ window: NSWindow) -> Bool {
        (window.identifier?.rawValue.hasPrefix("main") ?? false) || window.title == "Highball"
    }

    static var isOpen: Bool {
        NSApp.windows.contains { isMain($0) && ($0.isVisible || $0.isMiniaturized) }
    }

    /// Opens the main window if none is open; a no-op when one already is.
    static func ensureOpen() {
        if !isOpen { opener?() }
    }
}
