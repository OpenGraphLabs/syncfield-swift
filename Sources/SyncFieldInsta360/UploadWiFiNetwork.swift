import Foundation
import Network

#if os(iOS) && canImport(NetworkExtension)
import NetworkExtension
#endif

public struct UploadWiFiProfile: Codable, Equatable, Sendable {
    public let ssid: String
    public let passphrase: String
    public let isWEP: Bool

    public init?(ssid: String, passphrase: String, isWEP: Bool = false) {
        let normalizedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSSID.isEmpty else { return nil }
        self.ssid = normalizedSSID
        self.passphrase = passphrase
        self.isWEP = isWEP
    }
}

public enum UploadNetworkInterface: String, Codable, Equatable, Sendable {
    case wifi
    case cellular
    case wired
    case other
    case none
}

public struct UploadNetworkStatus: Codable, Equatable, Sendable {
    public let interface: UploadNetworkInterface
    public let ssid: String?
    public let isExpensive: Bool
    public let isConstrained: Bool

    public init(interface: UploadNetworkInterface,
                ssid: String?,
                isExpensive: Bool,
                isConstrained: Bool) {
        self.interface = interface
        self.ssid = ssid
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

public enum UploadWiFiRejoinState: String, Codable, Equatable, Sendable {
    case ready
    case timedOut
    case failed
}

public struct UploadWiFiRejoinResult: Codable, Equatable, Sendable {
    public let state: UploadWiFiRejoinState
    public let status: UploadNetworkStatus
    public let message: String?

    public init(state: UploadWiFiRejoinState,
                status: UploadNetworkStatus,
                message: String? = nil) {
        self.state = state
        self.status = status
        self.message = message
    }
}

/// Rejoins a caller-provided upload Wi-Fi profile after Insta360 AP ingest
/// and waits until iOS routes outgoing traffic over that Wi-Fi again.
public actor UploadWiFiReconnector {
    public static let shared = UploadWiFiReconnector()

    public init() {}

    public static func isReadyForUpload(
        status: UploadNetworkStatus,
        profile: UploadWiFiProfile?
    ) -> Bool {
        guard status.interface == .wifi, !status.isExpensive else {
            return false
        }

        guard let profile else {
            return true
        }
        return status.ssid == profile.ssid
    }

    public static func resolvedStatus(
        interface: UploadNetworkInterface,
        ssid: String?,
        isExpensive: Bool,
        isConstrained: Bool
    ) -> UploadNetworkStatus {
        let normalizedInterface: UploadNetworkInterface
        let hasSSID = !(ssid?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if hasSSID, interface == .none || interface == .other {
            normalizedInterface = .wifi
        } else {
            normalizedInterface = interface
        }

        return UploadNetworkStatus(
            interface: normalizedInterface,
            ssid: ssid,
            isExpensive: isExpensive,
            isConstrained: isConstrained)
    }

    public func currentStatus() async -> UploadNetworkStatus {
        async let path = currentPathStatus()
        async let ssid = currentSSID()
        let resolved = await path
        return Self.resolvedStatus(
            interface: resolved.interface,
            ssid: await ssid,
            isExpensive: resolved.isExpensive,
            isConstrained: resolved.isConstrained)
    }

    public func rejoin(
        profile: UploadWiFiProfile,
        timeoutSeconds: TimeInterval = 30,
        pollIntervalSeconds: TimeInterval = 1
    ) async -> UploadWiFiRejoinResult {
        do {
            try await apply(
                profile: profile,
                applyTimeoutSeconds: min(max(timeoutSeconds, 0), 8))
        } catch {
            return UploadWiFiRejoinResult(
                state: .failed,
                status: await currentStatus(),
                message: error.localizedDescription)
        }

        return await waitForUploadReady(
            profile: profile,
            timeoutSeconds: timeoutSeconds,
            pollIntervalSeconds: pollIntervalSeconds)
    }

    public func waitForUploadReady(
        profile: UploadWiFiProfile?,
        timeoutSeconds: TimeInterval = 30,
        pollIntervalSeconds: TimeInterval = 1
    ) async -> UploadWiFiRejoinResult {
        let timeoutNs = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
        let intervalNs = UInt64(max(0.1, pollIntervalSeconds) * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNs
        var last = await currentStatus()

        while DispatchTime.now().uptimeNanoseconds <= deadline {
            if Self.isReadyForUpload(status: last, profile: profile) {
                return UploadWiFiRejoinResult(state: .ready, status: last)
            }
            try? await Task.sleep(nanoseconds: intervalNs)
            last = await currentStatus()
        }

        return UploadWiFiRejoinResult(
            state: .timedOut,
            status: last,
            message: "upload Wi-Fi was not ready before timeout")
    }

    private struct PathSnapshot: Sendable {
        let interface: UploadNetworkInterface
        let isExpensive: Bool
        let isConstrained: Bool
    }

    private final class OneShotGate: @unchecked Sendable {
        private let lock = NSLock()
        private var didRun = false

        func run(_ block: () -> Void) {
            lock.lock()
            guard !didRun else {
                lock.unlock()
                return
            }
            didRun = true
            lock.unlock()
            block()
        }
    }

    private func currentPathStatus() async -> PathSnapshot {
        await withCheckedContinuation { cont in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "syncfield.upload-wifi.path")
            let gate = OneShotGate()

            @Sendable func finish(_ path: Network.NWPath?) {
                gate.run {
                    monitor.cancel()

                    guard let path, path.status == .satisfied else {
                        cont.resume(returning: PathSnapshot(
                            interface: .none,
                            isExpensive: path?.isExpensive ?? false,
                            isConstrained: path?.isConstrained ?? false))
                        return
                    }

                    let interface: UploadNetworkInterface
                    if path.usesInterfaceType(.wifi) {
                        interface = .wifi
                    } else if path.usesInterfaceType(.cellular) {
                        interface = .cellular
                    } else if path.usesInterfaceType(.wiredEthernet) {
                        interface = .wired
                    } else {
                        interface = .other
                    }

                    cont.resume(returning: PathSnapshot(
                        interface: interface,
                        isExpensive: path.isExpensive,
                        isConstrained: path.isConstrained))
                }
            }

            monitor.pathUpdateHandler = { path in
                finish(path)
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2.0) {
                finish(nil)
            }
        }
    }

    private func currentSSID() async -> String? {
        #if os(iOS) && canImport(NetworkExtension)
        return await withCheckedContinuation { cont in
            NEHotspotNetwork.fetchCurrent { network in
                cont.resume(returning: network?.ssid)
            }
        }
        #else
        return nil
        #endif
    }

    private func apply(
        profile: UploadWiFiProfile,
        applyTimeoutSeconds: TimeInterval = 8
    ) async throws {
        #if os(iOS) && canImport(NetworkExtension)
        let config: NEHotspotConfiguration
        if profile.passphrase.isEmpty {
            config = NEHotspotConfiguration(ssid: profile.ssid)
        } else {
            config = NEHotspotConfiguration(
                ssid: profile.ssid,
                passphrase: profile.passphrase,
                isWEP: profile.isWEP)
        }
        config.joinOnce = false

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    NEHotspotConfigurationManager.shared.apply(config) { error in
                        if let ns = error as NSError? {
                            if ns.domain == NEHotspotConfigurationErrorDomain,
                               ns.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                                cont.resume()
                                return
                            }
                            cont.resume(throwing: Insta360Error.hotspotApplyFailedWithKind(
                                kind: UploadWiFiApplyFailureKind.classify(ns),
                                detail: ns.localizedDescription))
                            return
                        }
                        cont.resume()
                    }
                }
            }
            group.addTask {
                let timeoutNs = UInt64(max(0, applyTimeoutSeconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: timeoutNs)
                throw Insta360Error.hotspotApplyFailedWithKind(
                    kind: .unknown,
                    detail: "upload Wi-Fi apply timed out after \(applyTimeoutSeconds)s")
            }
            _ = try await group.next()
            group.cancelAll()
        }
        #else
        throw Insta360Error.hotspotApplyFailedWithKind(
            kind: .unknown,
            detail: "upload Wi-Fi rejoin is only available on iOS")
        #endif
    }
}
