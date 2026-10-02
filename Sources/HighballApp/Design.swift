import AppKit
import SwiftUI

/// Shared visual language. Content stays opaque; glass belongs to navigation and controls.
enum HB {
    static let amber = Color(red: 0.94, green: 0.71, blue: 0.38)
    static let amberDeep = Color(red: 0.63, green: 0.40, blue: 0.11)
    static let ground = Color(red: 0.065, green: 0.070, blue: 0.082)
    static let card = Color.white.opacity(0.045)
    static let cardStroke = Color.white.opacity(0.085)
    static let good = Color(red: 0.45, green: 0.78, blue: 0.60)
    static let warn = amber
    static let bad = Color(red: 0.88, green: 0.48, blue: 0.48)

    static func motion(_ reduced: Bool) -> Animation? {
        reduced ? nil : .smooth(duration: 0.24)
    }

    static func eyebrow(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold))
            .kerning(1.2).foregroundStyle(.secondary)
    }
}

struct HighballMark: View {
    var size: CGFloat = 40
    // make-app.sh copies the mark into Contents/Resources for Bundle.main to find.
    private static let mark: NSImage? = Bundle.main.url(forResource: "HighballMark", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Group {
            if let image = Self.mark {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "wineglass.fill").resizable().scaledToFit().foregroundStyle(HB.amber)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct GlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let radius: CGFloat
    let interactive: Bool
    let selected: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(selected ? HB.amber.opacity(0.2) : HB.ground,
                               in: RoundedRectangle(cornerRadius: radius))
        } else {
            // Keep the macOS 14 deployment target and Xcode 16 contributor builds working.
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.tint(selected ? HB.amber.opacity(0.18) : .clear)
                    .interactive(interactive), in: RoundedRectangle(cornerRadius: radius))
            } else {
                fallback(content)
            }
            #else
            fallback(content)
            #endif
        }
    }

    private func fallback(_ content: Content) -> some View {
        content.background(.thinMaterial, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(HB.cardStroke))
    }
}

extension View {
    func hbGlass(radius: CGFloat = 16, interactive: Bool = false, selected: Bool = false) -> some View {
        modifier(GlassSurface(radius: radius, interactive: interactive, selected: selected))
    }

    func hbPanel(radius: CGFloat = 18) -> some View {
        background(HB.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(HB.cardStroke))
    }
}

struct HBGlassGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content() }
        } else { content() }
        #else
        content()
        #endif
    }
}

struct SettingsHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 27, weight: .semibold, design: .rounded))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsNavItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                    .frame(width: 22).foregroundStyle(selected ? HB.amber : .secondary)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(selected ? HB.amber.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Generous, quiet actions for content pages. Compact toolbar controls stay native.
struct HBActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if primary {
                configuration.label
                    .foregroundStyle(Color(red: 0.13, green: 0.08, blue: 0.01))
                    .padding(.horizontal, 22).padding(.vertical, 13)
                    .background(configuration.role == .destructive ? HB.bad : HB.amber, in: Capsule())
            } else {
                configuration.label.foregroundStyle(configuration.role == .destructive ? HB.bad : Color.primary)
                    .padding(.horizontal, 22).padding(.vertical, 13)
                    .hbGlass(radius: 24, interactive: true)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .opacity(enabled ? 1 : 0.4)
        .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
        .animation(HB.motion(reduceMotion), value: configuration.isPressed)
    }
}
