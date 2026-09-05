import AppKit
import SwiftUI

/// Shared modifier for menu-bar popovers.
///
/// SwiftUI menu bar windows do not always resize themselves after conditional
/// content changes. The embedded AppKit sizing view measures the rendered
/// content and adjusts the window height while preserving the top edge, which
/// avoids visible jumps near the menu bar.
struct MenuPanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(MenuPanelWindowSizer())
    }
}

extension View {
    func menuPanelSurface() -> some View {
        modifier(MenuPanelSurface())
    }
}

enum PanelColors {
    static let background = Color(nsColor: .controlBackgroundColor)
    static let sectionFill = Color(nsColor: .controlBackgroundColor)
    static let sectionStroke = Color(nsColor: .separatorColor)
    static let rowFill = Color(nsColor: .separatorColor).opacity(0.07)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
}

/// A quiet content layer for grouped controls inside the glass menu panel.
/// The window supplies the Liquid Glass surface, so cards use an adaptive
/// system fill instead of adding a second refractive layer.
struct PanelGroupedBackground<BackgroundShape: InsettableShape>: ViewModifier {
    let shape: BackgroundShape
    let fillOpacity: Double
    let strokeOpacity: Double

    func body(content: Content) -> some View {
        content
            .background(
                shape
                    .fill(PanelColors.sectionFill.opacity(fillOpacity))
            )
            .overlay {
                shape
                    .strokeBorder(PanelColors.sectionStroke.opacity(strokeOpacity), lineWidth: 1)
            }
    }
}

struct PanelMaterialCardBackground<BackgroundShape: InsettableShape>: ViewModifier {
    let shape: BackgroundShape
    let fillOpacity: Double
    let strokeOpacity: Double
    let lineWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .background(
                shape
                    .fill(PanelColors.background.opacity(fillOpacity))
            )
            .overlay {
                shape
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(strokeOpacity), lineWidth: lineWidth)
            }
    }
}

struct PanelSolidCardBackground<BackgroundShape: InsettableShape>: ViewModifier {
    let shape: BackgroundShape
    let fillOpacity: Double
    let strokeOpacity: Double

    func body(content: Content) -> some View {
        content
            .background(
                shape
                    .fill(PanelColors.background.opacity(fillOpacity))
            )
            .overlay {
                shape
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(strokeOpacity), lineWidth: 1)
            }
    }
}

extension View {
    func panelGroupedBackground<BackgroundShape: InsettableShape>(
        _ shape: BackgroundShape,
        fillOpacity: Double = 0.55,
        strokeOpacity: Double = 0.10
    ) -> some View {
        modifier(PanelGroupedBackground(shape: shape, fillOpacity: fillOpacity, strokeOpacity: strokeOpacity))
    }

    /// Regular material for content cards and grouped information. This keeps
    /// repeated content sections calm while the window and small badges carry
    /// the system's glass/material character.
    func panelMaterialCardBackground<BackgroundShape: InsettableShape>(
        _ shape: BackgroundShape,
        fillOpacity: Double = 0.34,
        strokeOpacity: Double = 0.22,
        lineWidth: CGFloat = 1
    ) -> some View {
        modifier(PanelMaterialCardBackground(shape: shape, fillOpacity: fillOpacity, strokeOpacity: strokeOpacity, lineWidth: lineWidth))
    }

    /// Cheaper card styling for hot-path surfaces such as the menu-bar popup.
    /// It avoids per-card material blur during the first open while preserving
    /// the same layout and contrast model.
    func panelSolidCardBackground<BackgroundShape: InsettableShape>(
        _ shape: BackgroundShape,
        fillOpacity: Double = 0.34,
        strokeOpacity: Double = 0.22
    ) -> some View {
        modifier(PanelSolidCardBackground(shape: shape, fillOpacity: fillOpacity, strokeOpacity: strokeOpacity))
    }

    /// Uses native glass styling for compact floating action buttons on newer
    /// macOS, while preserving standard bordered buttons on older systems.
    @ViewBuilder
    func panelFloatingButtonStyle(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
        #else
        if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
        #endif
    }

    /// Standard content-layer buttons. Native styles automatically inherit the
    /// current macOS control geometry without elevating every action onto glass.
    @ViewBuilder
    func panelContentButtonStyle(prominent: Bool = false) -> some View {
        if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// Fixed width for the compact menu-bar panel. Settings uses desktop-specific
/// metrics because it benefits from a wider, resizable window.
enum MenuPanelLayout {
    static let width: CGFloat = 336
}

private struct MenuPanelWindowSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> SizingView {
        SizingView()
    }

    func updateNSView(_ nsView: SizingView, context: Context) {
        nsView.scheduleWindowResize()
    }

    final class SizingView: NSView {
        private var isResizeScheduled = false
        private var lastScheduledSize: NSSize = .zero
        private var lastAppliedContentSize: NSSize = .zero

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleWindowResize()
        }

        override func layout() {
            super.layout()
            scheduleWindowResize()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scheduleWindowResize()
        }

        func scheduleWindowResize() {
            guard !isResizeScheduled else { return }
            let measuredSize = bounds.size
            guard measuredSize.width > 0, measuredSize.height > 0 else { return }
            guard abs(lastScheduledSize.width - measuredSize.width) > 0.5 ||
                  abs(lastScheduledSize.height - measuredSize.height) > 0.5 else {
                return
            }

            lastScheduledSize = measuredSize
            isResizeScheduled = true

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isResizeScheduled = false
                self.resizeWindowIfNeeded()
            }
        }

        private func resizeWindowIfNeeded() {
            guard let window, bounds.width > 0, bounds.height > 0 else { return }
            configureWindowAppearance(window)

            let measuredSize = bounds.size
            let targetContentSize = NSSize(width: ceil(measuredSize.width), height: ceil(measuredSize.height))
            guard targetContentSize.width.isFinite, targetContentSize.height.isFinite else { return }

            guard abs(lastAppliedContentSize.width - targetContentSize.width) > 0.5 ||
                  abs(lastAppliedContentSize.height - targetContentSize.height) > 0.5 else {
                return
            }

            lastAppliedContentSize = targetContentSize
            let targetFrameSize = window.frameRect(
                forContentRect: NSRect(origin: .zero, size: targetContentSize)
            ).size

            var frame = window.frame
            let topEdge = frame.maxY
            frame.size = targetFrameSize
            frame.origin.y = topEdge - frame.height

            // The menu bar anchors popovers by their top edge; preserving that
            // edge keeps expanding/collapsing panels visually stable.
            window.setFrame(frame, display: true, animate: false)
        }

        private func configureWindowAppearance(_ window: NSWindow) {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
}
