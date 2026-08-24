import SwiftUI

enum AmpestraTheme {
    static let accent = Color.accentColor
    static let accentBright = Color.accentColor
    static let blue = Color.accentColor
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let surfaceStrong = Color(uiColor: .tertiarySystemGroupedBackground)
    static let control = Color(uiColor: .tertiarySystemFill)
    static let raised = Color(uiColor: .secondarySystemFill)
    static let border = Color(uiColor: .separator).opacity(0.35)
    static let divider = Color(uiColor: .separator)
    static let mutedText = Color.secondary
    static let subtleText = Color(uiColor: .tertiaryLabel)
}

struct AmpestraBackdrop: View {
    var body: some View {
        AmpestraTheme.background
            .ignoresSafeArea()
    }
}

private struct AmpestraCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background(
                AmpestraTheme.surface,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

extension View {
    func ampestraCard(cornerRadius: CGFloat = 24) -> some View {
        modifier(AmpestraCardModifier(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    func ampestraGlassButton(prominent: Bool = false) -> some View {
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

    @ViewBuilder
    func ampestraGlassControl(cornerRadius: CGFloat = 20) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(
                .regular.interactive(),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            self.background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
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
            .background(
                AmpestraTheme.accent.opacity(0.14),
                in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            )
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
            .accessibilityHidden(true)
    }
}

struct NoticeToast: View {
    let message: String

    var body: some View {
        toastLabel
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private var toastLabel: some View {
        let label = Label(message, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 17)
            .padding(.vertical, 11)

        if #available(iOS 26.0, *) {
            label.glassEffect(.regular, in: .capsule)
        } else {
            label.background(.regularMaterial, in: Capsule())
        }
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
            .background(
                color.opacity(0.12),
                in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

struct SectionLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
