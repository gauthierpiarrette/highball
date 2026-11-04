import AppKit
import SwiftUI
import HighballKit

/// The achievement pop-up: a card over the game for a few seconds, with a sound. Windowed, it sits
/// in the game window's bottom-right corner; full screen or borderless (a window that covers its
/// screen), in that screen's corner, above the game. It never takes focus or a click,
/// so a game is never interrupted. Several unlocks show one after another.
@MainActor
final class AchievementToast {
    static let shared = AchievementToast()
    static let enabledDefaultsKey = "gogAchievementPopups"
    /// On unless turned off in Settings.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true }

    private var queue: [(achievement: GOGAchievement, gameWindow: CGRect?)] = []
    private var panel: NSPanel?
    private var showing = false

    /// `gameWindow` is the game's largest window as CGWindowList reports it, nil when it has none
    /// on screen (the card then goes to the screen the pointer is on).
    func show(_ achievement: GOGAchievement, gameWindow: CGRect? = nil) {
        queue.append((achievement, gameWindow))
        if !showing { next() }
    }

    private func next() {
        guard !queue.isEmpty else { showing = false; return }
        showing = true
        let (achievement, gameWindow) = queue.removeFirst()
        Task {
            // The badge is loaded first so the card never appears with an empty square.
            let badge: NSImage? = if let url = achievement.imageURL { await CachedGalleryImageLoader.shared.image(at: url) } else { nil }
            present(achievement, badge: badge, gameWindow: gameWindow)
        }
    }

    private func present(_ achievement: GOGAchievement, badge: NSImage?, gameWindow: CGRect?) {
        let host = NSHostingView(rootView: AchievementCard(achievement: achievement, badge: badge))
        let size = host.fittingSize
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.contentView = host
        let shown = Self.frame(for: size, gameWindow: gameWindow)
        panel.setFrame(shown.offsetBy(dx: 0, dy: -12), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSSound(named: "Glass")?.play()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
            panel.animator().setFrame(shown, display: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    self?.next()
                }
            })
        }
    }

    /// Where the card goes: the bottom-right corner of the game window when it is windowed and
    /// roomy enough, else of the game's screen (minus the menu bar and Dock), else of the screen
    /// the pointer is on.
    static func frame(for size: NSSize, gameWindow: CGRect?) -> NSRect {
        let margin: CGFloat = 20
        func corner(of box: NSRect) -> NSRect {
            NSRect(x: box.maxX - size.width - margin, y: box.minY + margin, width: size.width, height: size.height)
        }
        // CGWindowList bounds start at the top left of the main display; AppKit's at the bottom left.
        if let bounds = gameWindow, let main = NSScreen.screens.first {
            let window = NSRect(x: bounds.minX, y: main.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
            func overlap(_ screen: NSScreen) -> CGFloat {
                let i = screen.frame.intersection(window)
                return i.isNull ? 0 : i.width * i.height
            }
            if let screen = NSScreen.screens.max(by: { overlap($0) < overlap($1) }), overlap(screen) > 0 {
                let coversScreen = window.width >= screen.frame.width * 0.9 && window.height >= screen.frame.height * 0.9
                let inside = window.intersection(screen.visibleFrame)
                let roomy = !inside.isNull && inside.width >= size.width + 2 * margin && inside.height >= size.height + 2 * margin
                return corner(of: !coversScreen && roomy ? inside : screen.visibleFrame)
            }
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        return corner(of: screen?.visibleFrame ?? .zero)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver   // above a full-screen game
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false   // Highball is never the active app while a game runs
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct AchievementCard: View {
    let achievement: GOGAchievement
    let badge: NSImage?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let badge {
                    Image(nsImage: badge).resizable().interpolation(.high)
                } else {
                    Image(systemName: "trophy.fill").font(.title2).foregroundStyle(HB.amber)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white.opacity(0.08))
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Achievement unlocked").uppercased())
                    .font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(HB.amber)
                Text(achievement.name).font(.headline).lineLimit(1)
                if !achievement.description.isEmpty {
                    Text(achievement.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let rarity = Self.rarity(achievement) {
                    Text(rarity).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 250, alignment: .leading)
        }
        .padding(12)
        // Dark whatever the game shows behind it, so the text stays readable over a bright scene.
        .background {
            RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.6))
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .padding(1)
    }

    /// "Uncommon · 12.1% of players", or whichever half comet has.
    static func rarity(_ a: GOGAchievement) -> String? {
        var parts: [String] = []
        if !a.rarityLevel.isEmpty { parts.append(L(a.rarityLevel)) }
        if a.rarity > 0 {
            let share = a.rarity.formatted(.number.precision(.fractionLength(a.rarity < 10 ? 1 : 0)))
            parts.append(String(format: L("%@%% of players"), share))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
