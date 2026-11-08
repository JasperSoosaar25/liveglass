import SwiftUI

// MARK: - Liquid Glass design system
//
// On iOS 26 / 27 this uses Apple's *native* Liquid Glass APIs (glassEffect,
// GlassEffectContainer, glass button styles) exactly like the system apps.
// On iOS 17-25 it renders a handcrafted glass equivalent (ultra-thin material,
// hairline gradient stroke, soft shadows) so the look carries over on older iOS.

#if compiler(>=6.2)
@available(iOS 26.0, *)
private func liquidGlassValue(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
#endif

extension View {

    /// Wraps content in a Liquid Glass card.
    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat = 26, tint: Color? = nil,
                     interactive: Bool = false, padding: CGFloat = 16) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self
                .padding(padding)
                .glassEffect(liquidGlassValue(tint: tint, interactive: interactive),
                             in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.glassFallback(cornerRadius: cornerRadius, padding: padding)
        }
        #else
        self.glassFallback(cornerRadius: cornerRadius, padding: padding)
        #endif
    }

    @ViewBuilder
    private func glassFallback(cornerRadius: CGFloat, padding: CGFloat) -> some View {
        self
            .padding(padding)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
    }

    /// Soft shadow for glass chips on iOS 26 (no-op fallback needed for builder symmetry).
    @ViewBuilder
    func glassShadow() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 4)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Native scroll edge effect on iOS 26+, nothing on older iOS.
    @ViewBuilder
    func liquidScrollEdgeFix() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// Groups multiple glass shapes so iOS 26 can morph them (native Liquid Glass behavior).
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 24) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

/// Capsule button with native glass styling on iOS 26+, material capsule below.
struct GlassCapsuleButtonStyle: ButtonStyle {
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        Group {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                configuration.label
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassEffect(liquidGlassValue(tint: tint, interactive: true), in: Capsule())
                    .opacity(configuration.isPressed ? 0.85 : 1)
            } else {
                fallback(configuration: configuration)
            }
            #else
            fallback(configuration: configuration)
            #endif
        }
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }

    @ViewBuilder
    private func fallback(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Ambient backdrop
//
// Glass needs something colorful behind it to read as glass. Soft blurred orbs over a
// deep base — adaptive for light/dark mode.

struct AmbientBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            (dark ? Color(red: 0.045, green: 0.055, blue: 0.085)
                  : Color(red: 0.90, green: 0.93, blue: 0.97))
                .ignoresSafeArea()

            Circle()
                .fill(dark ? Color(red: 0.05, green: 0.45, blue: 0.50) : Color(red: 0.55, green: 0.85, blue: 0.88))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(x: -140, y: -320)
                .opacity(dark ? 0.55 : 0.5)

            Circle()
                .fill(dark ? Color(red: 0.35, green: 0.15, blue: 0.55) : Color(red: 0.78, green: 0.70, blue: 0.95))
                .frame(width: 380, height: 380)
                .blur(radius: 100)
                .offset(x: 150, y: -80)
                .opacity(dark ? 0.5 : 0.45)

            Circle()
                .fill(dark ? Color(red: 0.85, green: 0.25, blue: 0.35) : Color(red: 0.95, green: 0.72, blue: 0.76))
                .frame(width: 300, height: 300)
                .blur(radius: 95)
                .offset(x: -40, y: 380)
                .opacity(dark ? 0.35 : 0.35)
        }
    }
}

// MARK: - Small building blocks

struct StatusPill: View {
    let text: String
    var kind: PillKind = .neutral

    enum PillKind {
        case live, recording, neutral, error
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .tracking(0.4)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fill, in: Capsule())
            .foregroundStyle(foreground)
    }

    private var fill: Color {
        switch kind {
        case .live: return .red.opacity(0.9)
        case .recording: return .red
        case .error: return .orange.opacity(0.85)
        case .neutral: return .secondary.opacity(0.18)
        }
    }

    private var foreground: Color {
        switch kind {
        case .live, .recording: return .white
        case .error: return .white
        case .neutral: return .primary
        }
    }
}

extension WatchedUser {
    var pillKind: StatusPill.PillKind {
        if !lastError.isEmpty { return .error }
        if isLive { return .live }
        return .neutral
    }
}
