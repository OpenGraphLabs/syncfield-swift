// Tests/SyncFieldTests/AudioSessionInterruptionTests.swift
import XCTest
@testable import SyncField

#if canImport(AVFoundation) && os(iOS)
import AVFoundation

final class AudioSessionInterruptionTests: XCTestCase {

    /// GREEN: `.ended` notification triggers the recovery callback exactly once.
    func test_ended_notification_fires_onRecover_exactly_once() {
        let exp = expectation(description: "onRecover called")
        exp.assertForOverFulfill = true
        let handler = AudioSessionInterruptionHandler { exp.fulfill() }
        handler.start()
        defer { handler.stop() }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey:
                       AVAudioSession.InterruptionType.ended.rawValue])

        wait(for: [exp], timeout: 1.0)
    }

    /// `.began` must NOT trigger recovery — iOS deactivates the session on
    /// its own and we don't want to fight it.
    func test_began_notification_does_not_fire_onRecover() {
        let inv = expectation(description: "should NOT fire on .began")
        inv.isInverted = true
        let handler = AudioSessionInterruptionHandler { inv.fulfill() }
        handler.start()
        defer { handler.stop() }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey:
                       AVAudioSession.InterruptionType.began.rawValue])

        wait(for: [inv], timeout: 0.3)
    }

    /// After stop(), notifications must not invoke the callback.
    func test_stop_unsubscribes_observer() {
        let inv = expectation(description: "should NOT fire after stop")
        inv.isInverted = true
        let handler = AudioSessionInterruptionHandler { inv.fulfill() }
        handler.start()
        handler.stop()

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey:
                       AVAudioSession.InterruptionType.ended.rawValue])

        wait(for: [inv], timeout: 0.3)
    }

    /// start() must be idempotent — calling twice shouldn't double-fire.
    func test_start_is_idempotent() {
        let exp = expectation(description: "onRecover called once")
        exp.assertForOverFulfill = true
        let handler = AudioSessionInterruptionHandler { exp.fulfill() }
        handler.start()
        handler.start()
        defer { handler.stop() }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey:
                       AVAudioSession.InterruptionType.ended.rawValue])

        wait(for: [exp], timeout: 1.0)
    }

    /// A notification with no `AVAudioSessionInterruptionTypeKey` payload
    /// is malformed and must be ignored without crashing.
    func test_notification_without_type_key_is_ignored() {
        let inv = expectation(description: "should NOT fire on malformed note")
        inv.isInverted = true
        let handler = AudioSessionInterruptionHandler { inv.fulfill() }
        handler.start()
        defer { handler.stop() }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [:])

        wait(for: [inv], timeout: 0.3)
    }
}

#endif
