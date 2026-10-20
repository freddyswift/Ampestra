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
    private static let controlUnavailableError = "iPhone volume control isn't ready. Toggle Control speaker to try again."
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
    private var entrySnapshotTask: Task<Void, Never>?
    private var restorationTask: Task<Void, Never>?
    private var restorationGeneration = 0
    private var restorationBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private(set) var isRestoringVolume = false
    private var interpreter = OutputVolumeChangeInterpreter(initialVolume: 0.5)
    private weak var volumeSlider: UISlider?
    // Keep the native control alive until its asynchronous restore completes.
    private var retainedVolumeView: MPVolumeView?
    private var volumeControlIsInWindow = false
    private var originalVolume: Float?
    private var foregroundVolume: Float?
    private let readSystemVolume: () -> Float
    private let writeSystemVolume: ((Float) -> Void)?
    private let readVolumeControl: (() -> Float?)?
    private let audioSessionOperation: (@Sendable (Bool) throws -> Void)?
    private let entryReadingIsAuthoritative: Bool
    private var hasCapturedControlVolume = false
    private var hasAdjustedPhoneVolume = false
    private var audioSessionIsActive = false
    private var lastRestorationError: String?
    // Keep an unconfirmed restore across a quick background/foreground cycle.
    // Otherwise the temporary capture level becomes the next session's entry.
    private var pendingRestoration: (target: Float, startingVolume: Float)?
    private var foregroundRecovery: (target: Float, startingVolume: Float)?
    private var suppressedTarget: (volume: Float, expires: ContinuousClock.Instant)?
    private var wantsCapture = false
    private var isInterrupted = false
    private var isActivating = false
    private var activationRequestID = 0

    init(
        audioSession: AVAudioSession = .sharedInstance(),
        readSystemVolume: (() -> Float)? = nil,
        writeSystemVolume: ((Float) -> Void)? = nil,
        readVolumeControl: (() -> Float?)? = nil,
        audioSessionOperation: (@Sendable (Bool) throws -> Void)? = nil
    ) {
        self.audioSession = audioSession
        self.readSystemVolume = readSystemVolume ?? { audioSession.outputVolume }
        self.writeSystemVolume = writeSystemVolume
        self.readVolumeControl = readVolumeControl
        self.audioSessionOperation = audioSessionOperation
        entryReadingIsAuthoritative = readSystemVolume != nil && readVolumeControl == nil
        super.init()

        lifecycleMonitor = makeAudioSessionLifecycleMonitor(audioSession: audioSession) { [weak self] event in
            self?.handleLifecycleEvent(event)
        }
    }

    deinit {
        observation?.invalidate()
        recenterTask?.cancel()
        entrySnapshotTask?.cancel()
        restorationTask?.cancel()
        let backgroundTask = restorationBackgroundTask
        if backgroundTask != .invalid {
            Task { @MainActor in UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
    }

    func attach(volumeView: MPVolumeView) {
        guard let slider = volumeView.firstVolumeSlider else { return }
        let isInWindow = volumeView.window != nil
        guard slider !== volumeSlider || isInWindow != volumeControlIsInWindow else { return }
        retainedVolumeView = volumeView
        volumeSlider = slider
        volumeControlIsInWindow = isInWindow
        scheduleEntrySnapshot()
        startCaptureIfReady()

        if wantsCapture, isCapturing {
            recenterSystemVolume(after: .milliseconds(80))
        }
    }

    func start() {
        wantsCapture = true
        guard !isCapturing, !isActivating, !isInterrupted else { return }
        cancelRestoration()
        // Capture before asynchronous activation or recentering can change it.
        originalVolume = originalVolume ?? foregroundVolume
            ?? OutputVolumeChangeInterpreter.clamped(readSystemVolume())
        if audioSessionIsActive {
            scheduleEntrySnapshot()
            startCaptureIfReady()
            return
        }

        activateAudioSession(
            failureMessage: "Physical volume buttons are unavailable"
        )
    }

    func beginForegroundSession() {
        guard foregroundVolume == nil else { return }
        let current = OutputVolumeChangeInterpreter.clamped(readSystemVolume())
        let pendingEntry = pendingRestoration.flatMap { pending in
            // An inactive session's cached value cannot decide whether the
            // phone changed. Resolve that against the native control below.
            if !entryReadingIsAuthoritative { return pending.target }
            return abs(current - pending.startingVolume) < 0.005 || abs(current - pending.target) < 0.005
                ? pending.target : nil
        }
        foregroundRecovery = entryReadingIsAuthoritative ? nil : pendingRestoration
        cancelRestoration()
        hasAdjustedPhoneVolume = pendingEntry.map { abs(current - $0) >= 0.005 } ?? false
        hasCapturedControlVolume = entryReadingIsAuthoritative
        foregroundVolume = pendingEntry ?? current
        scheduleEntrySnapshot()
    }

    func endForegroundSession() {
        // Capture can stop earlier when a speaker disconnects, sleeps or changes
        // source. The entry value still belongs to the entire foreground session.
        if originalVolume == nil, hasAdjustedPhoneVolume {
            originalVolume = foregroundVolume
        }
        stop()
        entrySnapshotTask?.cancel()
        entrySnapshotTask = nil
        foregroundVolume = nil
        foregroundRecovery = nil
        hasCapturedControlVolume = false
        hasAdjustedPhoneVolume = false
    }

    func stop() {
        // Snapshot polling may repeatedly ask an already stopped controller to stop.
        // Avoid publishing state and queueing redundant audio-session deactivations.
        guard wantsCapture || isCapturing || isActivating || isInterrupted
                || originalVolume != nil else { return }
        captureEntryVolumeFromControl()
        wantsCapture = false
        isInterrupted = false
        activationRequestID &+= 1
        isActivating = false
        recenterTask?.cancel()
        recenterTask = nil
        entrySnapshotTask?.cancel()
        entrySnapshotTask = nil
        observation?.invalidate()
        observation = nil
        isCapturing = false
        audioSessionIsActive = false

        // If the control never became ready and we never changed phone volume,
        // leave it alone rather than writing a potentially stale session value.
        let exitVolume = hasCapturedControlVolume || hasAdjustedPhoneVolume || entryReadingIsAuthoritative
            ? originalVolume : nil
        if let exitVolume {
            phoneOutputVolume = exitVolume
        }
        originalVolume = nil
        suppressedTarget = nil

        if let exitVolume {
            restorePhoneVolume(exitVolume)
        } else {
            deactivateAudioSession()
        }
    }

    private func activateAudioSession(failureMessage: String) {
        activationRequestID &+= 1
        let requestID = activationRequestID
        isActivating = true

        let audioSession = audioSession
        let operation = audioSessionOperation
        audioSessionQueue.async { [weak self] in
            let result: Result<Void, Error> = Result {
                if let operation {
                    try operation(true)
                } else {
                    try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
                    try audioSession.setActive(true)
                }
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
            audioSessionIsActive = true
            isInterrupted = false
            lastError = lastRestorationError
            scheduleEntrySnapshot()
            startCaptureIfReady()
        case .failure(let error):
            audioSessionIsActive = false
            isCapturing = false
            lastError = "\(failureMessage): \(error.localizedDescription)"
        }
    }

    private func startCaptureIfReady() {
        guard wantsCapture, audioSessionIsActive, !isInterrupted, !isCapturing,
              hasCapturedControlVolume || entryReadingIsAuthoritative else { return }
        let current = readVolumeControl?() ?? volumeSlider?.value ?? readSystemVolume()
        phoneOutputVolume = OutputVolumeChangeInterpreter.clamped(current)
        interpreter.reset(to: current)
        installObservation()
        isCapturing = true
        if lastError == Self.controlUnavailableError { lastError = lastRestorationError }
        recenterSystemVolume(after: .milliseconds(80))
    }

    private func installObservation() {
        observation?.invalidate()
        let requestID = activationRequestID
        observation = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let newVolume = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard self?.activationRequestID == requestID else { return }
                self?.receiveOutputVolume(newVolume)
            }
        }
    }

    private func receiveOutputVolume(_ newVolume: Float) {
        guard wantsCapture, isCapturing, !isInterrupted else { return }
        guard hasCapturedControlVolume || entryReadingIsAuthoritative else { return }

        let newVolume = OutputVolumeChangeInterpreter.clamped(newVolume)
        phoneOutputVolume = newVolume

        if let target = suppressedTarget {
            if target.expires <= .now {
                suppressedTarget = nil
            } else if abs(newVolume - target.volume) < 0.005 {
                suppressedTarget = nil
                interpreter.reset(to: newVolume)
                return
            }
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

            guard self.volumeSlider != nil || self.writeSystemVolume != nil else {
                self.suppressedTarget = nil
                self.interpreter.reset(to: self.audioSession.outputVolume)
                return
            }

            let target: Float = 0.5
            self.captureEntryVolumeFromControl()
            guard self.hasCapturedControlVolume || self.entryReadingIsAuthoritative else { return }
            self.hasAdjustedPhoneVolume = true
            self.suppressedTarget = (target, .now + .milliseconds(250))
            self.interpreter.reset(to: target)
            self.setSystemVolume(target)
        }
    }

    private func setSystemVolume(_ volume: Float) {
        let volume = OutputVolumeChangeInterpreter.clamped(volume)
        if let writeSystemVolume {
            writeSystemVolume(volume)
            return
        }
        guard let volumeSlider else { return }
        volumeSlider.setValue(volume, animated: false)
        volumeSlider.sendActions(for: .valueChanged)
        volumeSlider.sendActions(for: .touchUpInside)
    }

    private func scheduleEntrySnapshot() {
        guard foregroundVolume != nil, !hasCapturedControlVolume,
              !hasAdjustedPhoneVolume || foregroundRecovery != nil,
              entrySnapshotTask == nil else { return }
        entrySnapshotTask = Task { @MainActor [weak self] in
            // Native slider creation and route setup can outlast the first layout.
            // Poll for a bounded period; never recenter without a saved reading.
            for _ in 0..<30 {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self else { return }
                self.captureEntryVolumeFromControl()
                if self.hasCapturedControlVolume {
                    self.entrySnapshotTask = nil
                    return
                }
            }
            guard let self else { return }
            self.entrySnapshotTask = nil
            if self.wantsCapture, self.audioSessionIsActive {
                self.lastError = Self.controlUnavailableError
            }
        }
    }

    private func captureEntryVolumeFromControl() {
        guard foregroundVolume != nil, !hasCapturedControlVolume,
              !hasAdjustedPhoneVolume || foregroundRecovery != nil else { return }
        // outputVolume can retain an inactive session's old reading. Let the
        // native volume control settle in its window before trusting its value.
        guard let controlVolume = nativeControlVolume else { return }
        let nativeVolume = OutputVolumeChangeInterpreter.clamped(controlVolume)
        let entryVolume: Float
        if let recovery = foregroundRecovery {
            // The native control may still show our own pending write. Preserve
            // that restore target only for values belonging to the old session;
            // a different native reading is the user's new opening volume.
            let isOldValue = abs(nativeVolume - recovery.startingVolume) < 0.005
                || abs(nativeVolume - recovery.target) < 0.005
            entryVolume = isOldValue ? recovery.target : nativeVolume
            hasAdjustedPhoneVolume = abs(nativeVolume - entryVolume) >= 0.005
            foregroundRecovery = nil
        } else {
            entryVolume = nativeVolume
        }
        foregroundVolume = entryVolume
        interpreter.reset(to: entryVolume)
        hasCapturedControlVolume = true
        if wantsCapture || originalVolume != nil { originalVolume = foregroundVolume }
        startCaptureIfReady()
    }

    private var nativeControlVolume: Float? {
        readVolumeControl?() ?? (retainedVolumeView?.window != nil ? volumeSlider?.value : nil)
    }

    private func restorePhoneVolume(_ target: Float) {
        let current = OutputVolumeChangeInterpreter.clamped(nativeControlVolume ?? readSystemVolume())
        // Inactive and background may both request the same restore. A slider
        // showing our attempted target must not replace the pre-restore value.
        let startingVolume = pendingRestoration.flatMap { pending in
            abs(pending.target - target) < 0.005 && abs(current - target) < 0.005
                ? pending.startingVolume : nil
        } ?? current
        cancelRestoration()
        pendingRestoration = (target, startingVolume)
        isRestoringVolume = true
        let generation = restorationGeneration
        // Start while the scene is leaving active state, allowing this short
        // restore to finish even if UIKit backgrounds the process immediately.
        restorationBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Restore iPhone volume") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.restorationGeneration == generation else { return }
                self.reportRestorationFailure()
                self.cancelRestoration()
                self.deactivateAudioSession()
            }
        }
        setSystemVolume(target)
        restorationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delays: [Duration] = [.milliseconds(40), .milliseconds(70), .milliseconds(120), .milliseconds(180)]
            for (index, delay) in delays.enumerated() {
                do { try await Task.sleep(for: delay) } catch { return }
                guard self.restorationGeneration == generation, !self.wantsCapture else { return }
                if abs(self.readSystemVolume() - target) < 0.005 {
                    let previousRestoreError = self.lastRestorationError
                    self.lastRestorationError = nil
                    if self.lastError == previousRestoreError { self.lastError = nil }
                    self.finishRestoration(generation: generation)
                    return
                }
                if index < delays.count - 1 { self.setSystemVolume(target) }
            }
            self.reportRestorationFailure()
            self.finishRestoration(generation: generation)
        }
    }

    private func reportRestorationFailure() {
        lastRestorationError = "iPhone volume restoration could not be confirmed. Check your volume in Control Centre."
        lastError = lastRestorationError
    }

    private func finishRestoration(generation: Int) {
        guard restorationGeneration == generation else { return }
        pendingRestoration = nil
        phoneOutputVolume = OutputVolumeChangeInterpreter.clamped(readSystemVolume())
        restorationTask = nil
        isRestoringVolume = false
        endRestorationBackgroundTask()
        deactivateAudioSession()
    }

    private func cancelRestoration() {
        restorationGeneration &+= 1
        restorationTask?.cancel()
        restorationTask = nil
        pendingRestoration = nil
        isRestoringVolume = false
        endRestorationBackgroundTask()
    }

    private func endRestorationBackgroundTask() {
        guard restorationBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(restorationBackgroundTask)
        restorationBackgroundTask = .invalid
    }

    private func deactivateAudioSession() {
        let audioSession = audioSession
        let operation = audioSessionOperation
        audioSessionQueue.async {
            if let operation { try? operation(false) }
            else { try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation]) }
        }
    }

    private func handleLifecycleEvent(_ event: AudioSessionLifecycleEvent) {
        switch event {
        case .interrupted:
            guard wantsCapture else { return }
            activationRequestID &+= 1
            isActivating = false
            isInterrupted = true
            audioSessionIsActive = false
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
        let view = ReadySystemVolumeView(frame: .zero)
        view.onReady = { [weak controller] view in controller?.attach(volumeView: view) }
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

private final class ReadySystemVolumeView: MPVolumeView {
    var onReady: ((MPVolumeView) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onReady?(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onReady?(self)
    }
}

private extension UIView {
    var firstVolumeSlider: UISlider? {
        if let slider = self as? UISlider { return slider }
        for subview in subviews {
            if let slider = subview.firstVolumeSlider { return slider }
        }
        return nil
    }
}
