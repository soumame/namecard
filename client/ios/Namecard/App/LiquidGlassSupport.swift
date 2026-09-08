import SwiftUI

/// Keeps content visually present beneath the system's floating navigation layer.
struct AppBackdrop: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            RadialGradient(
                colors: [Color.accentColor.opacity(0.14), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 440
            )
            RadialGradient(
                colors: [Color.cyan.opacity(0.08), .clear],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Nearby glass elements need one sampling region to blend and react correctly.
struct LiquidGlassControlGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// Uses the native Liquid Glass button styles while preserving the iOS 17 fallback.
    @ViewBuilder
    func adaptiveGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Custom editor controls remain interactive glass only on systems that support it.
    @ViewBuilder
    func adaptiveGlassToolSurface(selected: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if selected {
                self.glassEffect(
                    .regular.tint(Color.accentColor).interactive(),
                    in: .rect(cornerRadius: 12)
                )
            } else {
                self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
            }
        } else {
            self.background(
                selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
    }

    /// The floating iOS 26 tab bar can yield more space as scrollable content moves.
    @ViewBuilder
    func adaptiveTabBarBehavior() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// A temporary status panel should read as a functional layer above the canvas.
    @ViewBuilder
    func adaptiveGlassStatusSurface() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(in: .rect(cornerRadius: 16))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
