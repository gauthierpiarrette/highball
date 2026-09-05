import SwiftUI
import AppKit

/// Hands a SwiftUI view's hosting NSWindow to a callback once it exists. Used to mark the
/// Settings window non-restorable (issue #58): macOS window restoration otherwise brings a
/// Settings window that was open at quit back at the next launch, and SwiftUI then skips
/// opening the default main window because a window was already restored.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { configure(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let window = nsView.window { configure(window) } }
    }
}

/// The main (library) window must exist whenever the app is in front of the user. SwiftUI opens
/// it at launch on its own, except when window restoration restored something else first; and a
/// dock click with only Settings visible does not reopen it either. Views that can appear without
/// a main window register an opener here, and the delegate and Settings ask for one when needed.
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
