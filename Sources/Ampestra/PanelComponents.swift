import SwiftUI

/// Small status row used across onboarding, settings, and disconnected states.
/// The accessory slot keeps rows visually consistent while allowing buttons,
/// progress indicators, or no trailing content.
struct StatusRow<Accessory: View>: View {
    let title: String
    let detail: String?
    let systemImage: String
    let tint: Color
    @ViewBuilder var accessory: Accessory

    init(
        title: String,
        detail: String?,
        systemImage: String,
        tint: Color,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory()
    }

    init(title: String, detail: String?, systemImage: String, tint: Color) where Accessory == EmptyView {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = EmptyView()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(PanelColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)
            accessory
        }
    }
}
