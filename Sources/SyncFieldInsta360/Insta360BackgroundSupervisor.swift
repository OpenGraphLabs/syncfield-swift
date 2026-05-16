import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Process-wide observer of `UIApplication.didEnterBackgroundNotification`
/// and `UIApplication.willEnterForegroundNotification`. Translates those
/// transitions into `Insta360SupervisorEvent.backgroundEntered` /
/// `.foregroundEntered` for every supervised camera so the state machine
/// can pause heartbeats while idle in background, then re-probe on resume.
///
/// Hosts that don't import UIKit (Mac targets running unit tests, CLI tools)
/// get an inert no-op object — `recordingActive` injection still lets you
/// drive the events manually from tests.
public final class Insta360BackgroundSupervisor: @unchecked Sendable {
    public typealias RecordingActiveProvider = @Sendable () -> Bool

    private weak var coordinator: Insta360ConnectionCoordinator?
    private let recordingActiveProvider: RecordingActiveProvider
    private let config: Insta360CoordinatorConfig

    #if canImport(UIKit)
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    #endif

    public init(coordinator: Insta360ConnectionCoordinator,
                config: Insta360CoordinatorConfig = .shared,
                recordingActiveProvider: @escaping RecordingActiveProvider = { false }) {
        self.coordinator = coordinator
        self.config = config
        self.recordingActiveProvider = recordingActiveProvider
    }

    deinit {
        #if canImport(UIKit)
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    public func start() {
        guard config.backgroundBLEEnabled else {
            InstaLog.log(.bg, level: .info, "start_noop",
                         ["reason": "backgroundBLEEnabled=false"])
            return
        }
        #if canImport(UIKit)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleBackground()
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleForeground()
        }
        InstaLog.log(.bg, level: .info, "started")
        #endif
    }

    public func stop() {
        #if canImport(UIKit)
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        backgroundObserver = nil
        foregroundObserver = nil
        InstaLog.log(.bg, level: .info, "stopped")
        #endif
    }

    // MARK: - Public hooks (test-callable on any platform)

    public func handleBackground() {
        let recordingActive = recordingActiveProvider()
        InstaLog.log(.bg, level: .info, "did_enter_background",
                     ["recording_active": recordingActive])
        let coordinator = self.coordinator
        Task {
            guard let coordinator = coordinator else { return }
            for key in await coordinator.attachedBindingKeys() {
                await coordinator.feed(bindingKey: key,
                                       event: .backgroundEntered(recordingActive: recordingActive))
            }
        }
    }

    public func handleForeground() {
        InstaLog.log(.bg, level: .info, "will_enter_foreground")
        let coordinator = self.coordinator
        Task {
            guard let coordinator = coordinator else { return }
            for key in await coordinator.attachedBindingKeys() {
                await coordinator.feed(bindingKey: key, event: .foregroundEntered)
            }
        }
    }
}
