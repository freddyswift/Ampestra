import AVFAudio
import Combine
import MediaPlayer
import SwiftUI
import UIKit

/// Converts foreground-only system output-volume changes into speaker volume
/// button events. iOS does not expose the hardware buttons directly, so the
/// app observes `AVAudioSession.outputVolume` and keeps the system volume away
/// from its hard limits while capture is active.
@MainActor
final class HardwareVolumeButtonController: NSObject, ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var phoneOutputVolume: Float = 0.5
    @Published private(set) var lastError: String?

    var onPress: ((VolumeButtonDirection) -> Void)?

    private let audioSession: AVAudioSession
    private let audioSessionQueue = DispatchQueue(
        label: "com.freddyswift.ampestra.audio-session",
        qos: .userInitiated
    )
    private var observation: NSKeyValueObservation?
    private var lifecycleMonitor: AudioSessionLifecycleMonitoring?
    private var recenterTask: Task<Void, Never>?
    private var interpreter = OutputVolumeChangeInterpreter(initialVolume: 0.5)
    private weak var volumeSlider: UISlider?
    private var originalVolume: Float?
    private var suppressedTarget: Float?
    private var wantsCapture = false
    private var isInterrupted = false
    private var isActivating = false
    private var activationRequestID = 0

    init(audioSession: AVAudioSession = .sharedInstance()) {
        self.audioSession = audioSession
        super.init()

        lifecycleMonitor = makeAudioSessionLifecycleMonitor(audioSession: audioSession) { [weak self] event in
            self?.handleLifecycleEvent(event)
        }
    }

    deinit {
        observation?.invalidate()
    }

    func attach(volumeView: MPVolumeView) {
        if let slider = volumeView.allDescendants.lazy.compactMap({ $0 as? UISlider }).first {
            volumeSlider = slider
        }

        if wantsCapture, isCapturing, volumeSlider != nil {
            recenterSystemVolume(after: .zero)
        }
    }

    func start() {
        wantsCapture = true
        guard !isCapturing, !isActivating, !isInterrupted else { return }

        activateAudioSession(
            failureMessage: "Physical volume buttons are unavailable"
        )
    }

    func stop(mutePhone: Bool = false) {
        wantsCapture = false
        isInterrupted = false
        activationRequestID &+= 1
        isActivating = false
        recenterTask?.cancel()
        recenterTask = nil
        observation?.invalidate()
        observation = nil
        isCapturing = false

        let exitVolume = mutePhone ? 0 : originalVolume
        if let exitVolume {
            setSystemVolume(exitVolume)
            phoneOutputVolume = exitVolume
        }
        originalVolume = nil
        suppressedTarget = nil

        let audioSession = audioSession
        audioSessionQueue.async {
            try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    private func activateAudioSession(failureMessage: String) {
        activationRequestID &+= 1
        let requestID = activationRequestID
        isActivating = true

        let audioSession = audioSession
        audioSessionQueue.async { [weak self] in
            let result: Result<Void, Error> = Result {
                try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
                try audioSession.setActive(true)
            }

            Task { @MainActor [weak self] in
                self?.finishActivation(
                    result,
                    requestID: requestID,
                    failureMessage: failureMessage
                )
            }
        }
    }

    private func finishActivation(
        _ result: Result<Void, Error>,
        requestID: Int,
        failureMessage: String
    ) {
        guard requestID == activationRequestID else { return }
        isActivating = false
        guard wantsCapture else { return }

        switch result {
        case .success:
            let initialVolume = OutputVolumeChangeInterpreter.clamped(audioSession.outputVolume)
            originalVolume = originalVolume ?? initialVolume
            phoneOutputVolume = initialVolume
            interpreter.reset(to: initialVolume)
            isInterrupted = false
            lastError = nil
            installObservation()
            isCapturing = true
            recenterSystemVolume(after: .zero)
        case .failure(let error):
            isCapturing = false
            lastError = "\(failureMessage): \(error.localizedDescription)"
        }
    }

    private func installObservation() {
        observation?.invalidate()
        observation = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let newVolume = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.receiveOutputVolume(newVolume)
            }
        }
    }

    private func receiveOutputVolume(_ newVolume: Float) {
        guard wantsCapture, isCapturing, !isInterrupted else { return }

        let newVolume = OutputVolumeChangeInterpreter.clamped(newVolume)
        phoneOutputVolume = newVolume

        if let target = suppressedTarget, abs(newVolume - target) < 0.035 {
            suppressedTarget = nil
            interpreter.reset(to: newVolume)
            return
        }

        guard let direction = interpreter.direction(for: newVolume) else { return }
        onPress?(direction)

        let delay: Duration = OutputVolumeChangeInterpreter.shouldRecenter(newVolume)
            ? .milliseconds(55)
            : .milliseconds(420)
        recenterSystemVolume(after: delay)
    }

    private func recenterSystemVolume(after delay: Duration) {
        recenterTask?.cancel()
        recenterTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            guard let self, self.wantsCapture, self.isCapturing, !self.isInterrupted else { return }

            guard self.volumeSlider != nil else {
                self.suppressedTarget = nil
                self.interpreter.reset(to: self.audioSession.outputVolume)
                return
            }

            let target: Float = 0.5
            self.suppressedTarget = target
            self.interpreter.reset(to: target)
            self.setSystemVolume(target)
        }
    }

    private func setSystemVolume(_ volume: Float) {
        guard let volumeSlider else { return }
        let volume = OutputVolumeChangeInterpreter.clamped(volume)
        volumeSlider.setValue(volume, animated: false)
        volumeSlider.sendActions(for: .valueChanged)
    }

    private func handleLifecycleEvent(_ event: AudioSessionLifecycleEvent) {
        switch event {
        case .interrupted:
            activationRequestID &+= 1
            isActivating = false
            isInterrupted = true
            isCapturing = false
            recenterTask?.cancel()
        case .shouldResume:
            guard isInterrupted, wantsCapture, !isActivating else { return }
            activateAudioSession(
                failureMessage: "Physical volume buttons could not resume"
            )
        case .shouldNotResume:
            // Keep capture suspended until the system sends a later recommendation
            // or the user explicitly restarts it.
            break
        }
    }
}

private enum AudioSessionLifecycleEvent {
    case interrupted
    case shouldResume
    case shouldNotResume
}

private protocol AudioSessionLifecycleMonitoring: AnyObject {}

@MainActor
private func makeAudioSessionLifecycleMonitor(
    audioSession: AVAudioSession,
    handler: @escaping @MainActor (AudioSessionLifecycleEvent) -> Void
) -> AudioSessionLifecycleMonitoring {
    if #available(iOS 27.0, *) {
        ModernAudioSessionLifecycleMonitor(
            audioSession: audioSession,
            handler: handler
        )
    } else {
        LegacyAudioSessionLifecycleMonitor(
            audioSession: audioSession,
            handler: handler
        )
    }
}

@available(iOS 27.0, *)
@MainActor
private final class ModernAudioSessionLifecycleMonitor: AudioSessionLifecycleMonitoring {
    private var deactivationObserver: NotificationCenter.ObservationToken?
    private var resumptionObserver: NotificationCenter.ObservationToken?

    init(
        audioSession: AVAudioSession,
        handler: @escaping @MainActor (AudioSessionLifecycleEvent) -> Void
    ) {
        deactivationObserver = NotificationCenter.default.addObserver(
            of: audioSession,
            for: .didBecomeInactive
        ) { message in
            switch message.deactivationResult {
            case .systemInterruption:
                handler(.interrupted)
            case .appDeactivated:
                break
            @unknown default:
                break
            }
        }
        resumptionObserver = NotificationCenter.default.addObserver(
            of: audioSession,
            for: .resumptionRecommendation
        ) { message in
            switch message.recommendation {
            case .shouldResume:
                handler(.shouldResume)
            case .shouldNotResume:
                handler(.shouldNotResume)
            @unknown default:
                break
            }
        }
    }

    deinit {
        if let deactivationObserver {
            NotificationCenter.default.removeObserver(deactivationObserver)
        }
        if let resumptionObserver {
            NotificationCenter.default.removeObserver(resumptionObserver)
        }
    }
}

@MainActor
private final class LegacyAudioSessionLifecycleMonitor: AudioSessionLifecycleMonitoring {
    private static let interruptionNotification = Notification.Name(
        "AVAudioSessionInterruptionNotification"
    )
    private static let interruptionTypeKey = "AVAudioSessionInterruptionTypeKey"
    private static let interruptionOptionKey = "AVAudioSessionInterruptionOptionKey"
    private static let interruptionEnded: UInt = 0
    private static let interruptionBegan: UInt = 1
    private static let shouldResume: UInt = 1

    private var interruptionObserver: NSObjectProtocol?

    init(
        audioSession: AVAudioSession,
        handler: @escaping @MainActor (AudioSessionLifecycleEvent) -> Void
    ) {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: Self.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { notification in
            Task { @MainActor in
                guard let rawType = notification.userInfo?[Self.interruptionTypeKey] as? UInt else {
                    return
                }

                switch rawType {
                case Self.interruptionBegan:
                    handler(.interrupted)
                case Self.interruptionEnded:
                    let rawOptions = notification.userInfo?[Self.interruptionOptionKey] as? UInt ?? 0
                    let recommendation: AudioSessionLifecycleEvent = rawOptions & Self.shouldResume != 0
                        ? .shouldResume
                        : .shouldNotResume
                    handler(recommendation)
                default:
                    break
                }
            }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }
}

struct SystemVolumeCaptureView: UIViewRepresentable {
    let controller: HardwareVolumeButtonController

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        view.alpha = 0.001
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        DispatchQueue.main.async {
            controller.attach(volumeView: view)
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        uiView.clipsToBounds = true
        controller.attach(volumeView: uiView)
    }
}

private extension UIView {
    var allDescendants: [UIView] {
        subviews + subviews.flatMap(\.allDescendants)
    }
}
