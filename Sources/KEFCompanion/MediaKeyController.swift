import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class MediaKeyController {
    enum ActivationResult {
        case working
        case missingAccessibility
        case failed
    }

    static var hasListenAccess: Bool {
        CGPreflightListenEventAccess()
    }

    static var hasAccessibilityAccess: Bool {
        AXIsProcessTrusted()
    }

    static func requestListenAccess() {
        _ = CGRequestListenEventAccess()
    }

    static func requestAccessibilityAccess() {
        // The imported SDK declaration is mutable for C ABI compatibility and
        // therefore fails Swift's strict-concurrency checks. The documented
        // Core Accessibility key has this stable string value.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private enum MediaKey {
        static let eventType = 14
        static let eventSubtype = 8
        static let volumeUp = 0
        static let volumeDown = 1
        static let mute = 7
        static let keyDownState = 0xA
        static let repeatMask = 0x1
    }

    private enum MediaKeyAction {
        case volumeDelta(Int)
        case muteToggle
    }

    private let onVolumeDelta: (Int) -> Bool
    private let onMuteToggle: () -> Bool
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// `onVolumeDelta` returns whether the app consumed the event. Returning
    /// false lets macOS handle the original volume key event normally.
    init(onVolumeDelta: @escaping (Int) -> Bool, onMuteToggle: @escaping () -> Bool) {
        self.onVolumeDelta = onVolumeDelta
        self.onMuteToggle = onMuteToggle
    }

    func activate() -> ActivationResult {
        guard Self.hasAccessibilityAccess else {
            invalidate()
            return .missingAccessibility
        }

        if eventTap == nil {
            installEventTap()
        }

        if eventTap != nil {
            return .working
        }

        return .failed
    }

    func invalidate() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func installEventTap() {
        guard eventTap == nil else { return }

        // Media keys arrive as system-defined events. The event tap needs both
        // Input Monitoring to observe keys and Accessibility to suppress events
        // when KEF volume routing is active.
        let eventMask = CGEventMask(1 << MediaKey.eventType)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let controller = Unmanaged<MediaKeyController>.fromOpaque(userInfo).takeUnretainedValue()
                return controller.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        self.eventTap = eventTap
        self.runLoopSource = source
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let action = mediaKeyAction(for: event) else {
            return Unmanaged.passUnretained(event)
        }

        let wasConsumed = switch action {
        case .volumeDelta(let delta):
            onVolumeDelta(delta)
        case .muteToggle:
            onMuteToggle()
        }

        if wasConsumed {
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func mediaKeyAction(for event: CGEvent) -> MediaKeyAction? {
        guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
        guard nsEvent.subtype.rawValue == MediaKey.eventSubtype else { return nil }

        // Apple exposes media key details in the packed `data1` field. The high
        // word is the key code; the low word contains key up/down/repeat flags.
        let data = Int(nsEvent.data1)
        let keyCode = (data & 0xFFFF0000) >> 16
        let keyFlags = data & 0x0000FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == MediaKey.keyDownState
        let isRepeat = (keyFlags & MediaKey.repeatMask) != 0

        switch keyCode {
        case MediaKey.volumeUp:
            guard isKeyDown || isRepeat else { return nil }
            return .volumeDelta(1)
        case MediaKey.volumeDown:
            guard isKeyDown || isRepeat else { return nil }
            return .volumeDelta(-1)
        case MediaKey.mute:
            guard isKeyDown, !isRepeat else { return nil }
            return .muteToggle
        default:
            return nil
        }
    }
}
