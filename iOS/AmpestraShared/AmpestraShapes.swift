import SwiftUI

/// Shared corner treatment for the remote, connection flow, Siri and widgets.
/// System controls such as sheets and grouped forms keep their native shapes.
enum AmpestraShapes {
    static let cardCornerRadius: CGFloat = 24
    static let controlCornerRadius: CGFloat = 16
    static let iconCornerRadius: CGFloat = 12

    static let card = RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    static let control = RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
    static let icon = RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous)
    static let controlButtonBorder = ButtonBorderShape.roundedRectangle(radius: controlCornerRadius)
}
