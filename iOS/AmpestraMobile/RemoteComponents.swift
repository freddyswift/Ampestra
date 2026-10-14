import SwiftUI

enum AmpestraTheme {
    static let accent = Color.accentColor
    static let accentBright = Color.accentColor
    static let onAccent = Color(uiColor: .systemBackground)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let surfaceStrong = Color(uiColor: .tertiarySystemGroupedBackground)
    static let control = Color(uiColor: .tertiarySystemFill)
    // Opaque secondary text keeps sufficient contrast over both cards and glass.
    static let mutedText = Color(uiColor: UIColor { traits in
        if traits.accessibilityContrast == .high {
            return .label
        }
        return traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.70, green: 0.72, blue: 0.76, alpha: 1)
            : UIColor(red: 0.36, green: 0.38, blue: 0.42, alpha: 1)
    })
}

struct AmpestraBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            AmpestraTheme.background

            if !reduceTransparency {
                LinearGradient(
                    colors: [
                        AmpestraTheme.accent.opacity(colorScheme == .dark ? 0.09 : 0.07),
                        AmpestraTheme.accent.opacity(colorScheme == .dark ? 0.025 : 0.018),
                        .clear,
                    ],
                    startPoint: .topTrailing,
                    endPoint: .center
                )

                RadialGradient(
                    colors: [
                        AmpestraTheme.accent.opacity(colorScheme == .dark ? 0.055 : 0.035),
                        .clear,
                    ],
                    center: UnitPoint(x: 0.5, y: 0.47),
                    startRadius: 0,
                    endRadius: 360
                )
            }
        }
        .ignoresSafeArea()
    }
}

private struct AmpestraCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        let shape = AmpestraShapes.card

        content
            .background {
                shape.fill(AmpestraTheme.surface)

                if !reduceTransparency {
                    shape.fill(.regularMaterial)
                    shape.fill(
                        AmpestraTheme.surface.opacity(colorScheme == .dark ? 0.56 : 0.68)
                    )
                }
            }
            .overlay {
                shape.strokeBorder(cardBorderColor, lineWidth: cardBorderWidth)
            }
            .shadow(
                color: colorScheme == .dark ? Color.black.opacity(0.22) : .clear,
                radius: colorScheme == .dark ? 14 : 0,
                x: 0,
                y: colorScheme == .dark ? 6 : 0
            )
    }

    private var cardBorderColor: Color {
        if colorSchemeContrast == .increased {
            return colorScheme == .dark
                ? Color.white.opacity(0.28)
                : Color.black.opacity(0.20)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.09)
            : Color.black.opacity(0.055)
    }

    private var cardBorderWidth: CGFloat {
        colorSchemeContrast == .increased ? 1.25 : 0.75
    }
}

extension View {
    func ampestraCard() -> some View {
        modifier(AmpestraCardModifier())
    }

    @ViewBuilder
    func ampestraGlassButton(
        prominent: Bool = false,
        shape: ButtonBorderShape = AmpestraShapes.controlButtonBorder
    ) -> some View {
        if prominent {
            self.buttonStyle(.glassProminent)
                .buttonBorderShape(shape)
        } else {
            self.buttonStyle(.glass)
                .buttonBorderShape(shape)
        }
    }

}

struct AmpestraMark: View {
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(AmpestraTheme.accent)
            .frame(width: size, height: size)
            .background {
                AmpestraIconBadgeBackground(color: AmpestraTheme.accent)
            }
            .accessibilityHidden(true)
    }
}

struct ConnectionDot: View {
    let state: SpeakerConnectionState

    private var color: Color {
        switch state {
        case .connected:
            .green
        case .connecting, .reconnecting:
            .orange
        case .failed:
            .red
        case .disconnected:
            .secondary
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.28), radius: 3)
            .accessibilityHidden(true)
    }
}

struct RemoteIcon: View {
    let systemName: String
    var color = AmpestraTheme.accent
    var size: CGFloat = 42

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background {
                AmpestraIconBadgeBackground(color: color)
            }
            .accessibilityHidden(true)
    }
}

private struct AmpestraIconBadgeBackground: View {
    let color: Color

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let shape = AmpestraShapes.icon

        shape
            .fill(
                LinearGradient(
                    colors: [
                        color.opacity(colorScheme == .dark ? 0.19 : 0.13),
                        color.opacity(colorScheme == .dark ? 0.10 : 0.065),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                shape.strokeBorder(
                    color.opacity(colorSchemeContrast == .increased ? 0.38 : 0.18),
                    lineWidth: colorSchemeContrast == .increased ? 1.25 : 0.75
                )
            }
    }
}

struct SectionLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AmpestraTheme.mutedText)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AmpestraTheme.mutedText)
            }
        }
    }
}
