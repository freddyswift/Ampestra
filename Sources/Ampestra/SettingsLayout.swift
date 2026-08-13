import AppKit
import SwiftUI

enum SettingsMetrics {
    static let windowWidth: CGFloat = 520
    static let generalPageHeight: CGFloat = 490
    static let connectionPageHeight: CGFloat = 420
    static let segmentedControlWidth: CGFloat = 240
}

/// SwiftUI's macOS segmented `Picker` keeps its intrinsic label-based width,
/// which leaves adjacent settings controls with visibly different trailing
/// edges. This wrapper lets AppKit distribute every segment across one width.
struct SettingsSegmentedControl<Value: Hashable>: NSViewRepresentable {
    let accessibilityLabel: String
    let options: [(title: String, value: Value)]
    @Binding var selection: Value
    let width: CGFloat

    init(
        accessibilityLabel: String,
        options: [(title: String, value: Value)],
        selection: Binding<Value>,
        width: CGFloat = SettingsMetrics.segmentedControlWidth
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.options = options
        self._selection = selection
        self.width = width
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(control: self)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: options.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.controlSize = .small
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel(accessibilityLabel)
        updateSelection(in: control)
        return control
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        context.coordinator.control = self
        updateSelection(in: nsView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSSegmentedControl,
        context: Context
    ) -> CGSize? {
        CGSize(width: width, height: nsView.fittingSize.height)
    }

    private func updateSelection(in control: NSSegmentedControl) {
        control.selectedSegment = options.firstIndex(where: { $0.value == selection }) ?? -1
    }

    final class Coordinator: NSObject {
        var control: SettingsSegmentedControl

        init(control: SettingsSegmentedControl) {
            self.control = control
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard control.options.indices.contains(sender.selectedSegment) else { return }
            control.selection = control.options[sender.selectedSegment].value
        }
    }
}
