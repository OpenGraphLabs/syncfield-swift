import Foundation

public enum PhoneAuthorizationCacheState: Sendable, Equatable {
    case unknown
    case authorized(at: Date)
    case failed
}

internal enum Insta360PhoneAuthorizationProbeResult: Sendable, Equatable {
    case authorized
    case unauthorized
    case systemBusy
    case connectedByOtherPhone
    case connectedByOtherWatch
    case connectedByOtherCyclocomputer
}

internal enum Insta360PhoneAuthorizationInitialAction: Sendable, Equatable {
    case authorized
    case waitForUserDecision
    case fail(Insta360PhoneAuthorizationProbeResult)
}

internal enum Insta360PhoneAuthorizationUserResult: Sendable, Equatable {
    case unknown
    case success
    case reject
    case timeout
    case systemBusy
}

internal func insta360PhoneAuthorizationInitialAction(
    rawState: UInt
) -> Insta360PhoneAuthorizationInitialAction {
    switch rawState {
    case 0:
        return .authorized
    case 1:
        return .waitForUserDecision
    case 2:
        return .fail(.systemBusy)
    case 3:
        return .fail(.connectedByOtherPhone)
    case 4:
        return .fail(.connectedByOtherWatch)
    case 5:
        return .fail(.connectedByOtherCyclocomputer)
    default:
        return .fail(.unauthorized)
    }
}

internal func insta360PhoneAuthorizationUserResult(
    rawResult: UInt
) -> Insta360PhoneAuthorizationUserResult {
    switch rawResult {
    case 1: return .success
    case 2: return .reject
    case 3: return .timeout
    case 4: return .systemBusy
    default: return .unknown
    }
}
