import Foundation
import NamecardCore
import XCTest
@testable import Namecard

private actor RetryClock: TransferClock {
    var time: TimeInterval = 0
    func now() -> TimeInterval { time }
    func sleep(seconds: TimeInterval) { time += seconds }
}

private actor RegisterReadFixture {
    let error: any Error
    var remaining: Int
    var calls = 0
    init(_ error: any Error, count: Int) { self.error = error; remaining = count }
    func read() throws -> UInt8 {
        calls += 1
        if remaining > 0 { remaining -= 1; throw error }
        return 0x03
    }
}

final class NFCRecoveryPolicyTests: XCTestCase {
    func testTransientControlReadsRecoverWithoutReplayingMailboxWrites() async throws {
        let fixture = RegisterReadFixture(MailboxTransportError.transient("AD 102 ISO15693=0f"), count: 2)
        let clock = RetryClock()
        let result = try await MailboxControlReader.read(deadline: 10, clock: clock) { try await fixture.read() }
        XCTAssertEqual(result, 3)
        let calls = await fixture.calls
        let elapsed = await clock.now()
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(elapsed, 0.3, accuracy: 0.0001)
    }

    func testControlRetryLimitDeadlineAndTerminalErrors() async {
        let cases: [(any Error, TimeInterval, Int)] = [
            (MailboxTransportError.transient("AD timeout"), 10, 3),
            (MailboxTransportError.transient("AD timeout"), 0.2, 1),
            (MailboxTransportError.connectionLost("tag lost"), 10, 1),
            (AppFailure("MB_MODE unavailable"), 10, 1),
            (CancellationError(), 10, 1),
        ]
        for (error, deadline, expectedCalls) in cases {
            let fixture = RegisterReadFixture(error, count: 10)
            do {
                _ = try await MailboxControlReader.read(deadline: deadline, clock: RetryClock()) { try await fixture.read() }
                XCTFail("Invalid read succeeded")
            } catch { }
            let calls = await fixture.calls
            XCTAssertEqual(calls, expectedCalls)
        }
    }

    func testCancelledControlReadDoesNotIssueCommand() async {
        let fixture = RegisterReadFixture(MailboxTransportError.transient("AD timeout"), count: 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await MailboxControlReader.read(deadline: 10, clock: RetryClock()) { try await fixture.read() }
                XCTFail("Cancelled command issued")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
        let calls = await fixture.calls
        XCTAssertEqual(calls, 0)
    }

    func testSystemBusyBackoffIsBoundedAndSuccessfulActivationResetsIt() {
        var timing = NFCSessionTiming()
        XCTAssertEqual(timing.ended(systemBusy: false), 1)
        XCTAssertEqual(timing.ended(systemBusy: true), 2)
        XCTAssertEqual(timing.ended(systemBusy: true), 4)
        XCTAssertEqual(timing.ended(systemBusy: true), 6)
        XCTAssertEqual(timing.ended(systemBusy: true), 6)
        timing.becameActive()
        XCTAssertEqual(timing.ended(systemBusy: true), 2)
    }

    func testSystemSheetUpdatesAreLimitedButErrorsAndPhaseChangesAreImmediate() {
        var limiter = NFCAlertRateLimit()
        XCTAssertTrue(limiter.shouldSend("starting", now: 0))
        for i in 1..<10 { XCTAssertFalse(limiter.shouldSend("DATA \(i)", now: Double(i) / 10)) }
        XCTAssertTrue(limiter.shouldSend("DATA 10", now: 1))
        XCTAssertFalse(limiter.shouldSend("DATA 10", now: 2))
        XCTAssertTrue(limiter.shouldSend("connection lost", now: 1.1, force: true))
        XCTAssertFalse(limiter.shouldSend("connection lost", now: 1.2, force: true))
        XCTAssertTrue(limiter.shouldSend("completed", now: 1.2, force: true))
    }
}
