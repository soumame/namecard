import Foundation
import XCTest
@testable import NamecardCore

final class LinkFeedbackTests: XCTestCase {
    func testUnknownZeroAndStaleSamplesNeverProduceGoodFeedback() throws {
        var guide = LinkFeedback()
        guide.begin()
        XCTAssertNil(guide.pulse(now: 0))
        guide.receive(try ack(vdd: 0), responseSeconds: 0.1, now: 0)
        XCTAssertNil(guide.pulse(now: 0.1))
        try stabilize(&guide)
        XCTAssertEqual(guide.state, .stable)
        XCTAssertNil(guide.pulse(now: 2.1))
        XCTAssertEqual(guide.state, .waiting)
        guide.receive(try ack(), responseSeconds: 0.1, now: 2.2)
        XCTAssertEqual(guide.state, .settling, "Old good samples cannot establish a new lock")
    }

    func testStableRequiresSeveralACKsAndLockIsDistinctAndRateLimited() throws {
        var guide = LinkFeedback()
        guide.begin()
        guide.receive(try ack(), responseSeconds: 0.1, now: 0)
        XCTAssertEqual(guide.state, .settling)
        XCTAssertEqual(guide.pulse(now: 0), .approaching)
        guide.receive(try ack(), responseSeconds: 0.1, now: 0.3)
        XCTAssertNil(guide.pulse(now: 0.3))
        guide.receive(try ack(), responseSeconds: 0.1, now: 0.6)
        XCTAssertEqual(guide.pulse(now: 0.6), .locked)
        guide.receive(try ack(), responseSeconds: 0.1, now: 1.5)
        XCTAssertNil(guide.pulse(now: 1.5))
        guide.receive(try ack(), responseSeconds: 0.1, now: 2.7)
        XCTAssertEqual(guide.pulse(now: 2.7), .gentle)
    }

    func testSlowOrLowVoltageACKIsNotStableEvenAtNominalRailVoltage() throws {
        var guide = LinkFeedback()
        guide.begin()
        guide.receive(try ack(vdd: 3300), responseSeconds: 0.9, now: 0)
        XCTAssertEqual(guide.state, .weak)
        XCTAssertNil(guide.pulse(now: 0))
        guide.receive(try ack(vdd: 3000), responseSeconds: 0.1, now: 0.2)
        XCTAssertEqual(guide.state, .weak)
        guide.receive(try ack(vdd: 3100), responseSeconds: 0.1, now: 0.4)
        XCTAssertEqual(guide.state, .settling)
        XCTAssertEqual(guide.pulse(now: 0.4), .gentle)
    }

    func testExecuteSilencesBeforeACKAndReadyOrCompleteCannotRestartPulses() throws {
        var guide = LinkFeedback()
        guide.begin()
        try stabilize(&guide)
        guide.willSend(.execute)
        XCTAssertNil(guide.pulse(now: 0.7))
        guide.failed(now: 0.8) // EXECUTE ACK lost; display may already be refreshing.
        for state: UInt8 in [2, 3, 5, 6] {
            guide.receive(try ack(state: state), responseSeconds: 0.1, now: 1)
            XCTAssertEqual(guide.state, .updating)
            XCTAssertNil(guide.pulse(now: 1))
        }
    }

    func testQuietCommitAndExistingRefreshDoNotReuseGoodVoltage() throws {
        var guide = LinkFeedback()
        guide.begin()
        try stabilize(&guide)
        guide.willSend(.commit)
        XCTAssertNil(guide.pulse(now: 0.7))
        guide.receive(try ack(quiet: 2000), responseSeconds: 0.1, now: 0.8)
        XCTAssertNil(guide.pulse(now: 0.8))
        guide.receive(try ack(state: 5), responseSeconds: 0.1, now: 1)
        XCTAssertEqual(guide.state, .updating)
        XCTAssertNil(guide.pulse(now: 1))
    }

    func testFailureClearsHintAndNeedsFreshSuccessesAfterCooldown() throws {
        var guide = LinkFeedback()
        guide.begin()
        try stabilize(&guide)
        guide.failed(now: 0.7)
        XCTAssertNil(guide.pulse(now: 0.7))
        guide.receive(try ack(), responseSeconds: 0.1, now: 0.8)
        XCTAssertEqual(guide.state, .weak)
        XCTAssertNil(guide.pulse(now: 0.8))
        try stabilize(&guide, start: 3)
        XCTAssertEqual(guide.state, .stable)
    }

    func testNewSessionAndNewPatternClearAllOldMeasurements() throws {
        var guide = LinkFeedback()
        guide.begin()
        try stabilize(&guide)
        guide.willSend(.execute)
        guide.willSend(.pattern)
        XCTAssertEqual(guide.state, .waiting)
        XCTAssertNil(guide.pulse(now: 1))
        try stabilize(&guide, start: 2)
        guide.end()
        guide.receive(try ack(), responseSeconds: 0.1, now: 3)
        XCTAssertEqual(guide.state, .idle)
        XCTAssertNil(guide.pulse(now: 3))
        guide.begin()
        XCTAssertNil(guide.pulse(now: 4))
    }

    func testFWErrorCompleteAndInvalidTimingCannotBecomePlacementHints() throws {
        for (state, error, elapsed): (UInt8, UInt8, TimeInterval) in [(7, 15, 0.1), (6, 0, 0.1), (1, 0, .nan)] {
            var guide = LinkFeedback()
            guide.begin()
            try stabilize(&guide)
            guide.receive(try ack(state: state, error: error), responseSeconds: elapsed, now: 1)
            XCTAssertEqual(guide.state, .waiting)
            XCTAssertNil(guide.pulse(now: 1))
        }
    }

    private func stabilize(_ guide: inout LinkFeedback, start: TimeInterval = 0) throws {
        for time in [start, start + 0.3, start + 0.6] {
            guide.receive(try ack(), responseSeconds: 0.1, now: time)
        }
    }

    private func ack(vdd: UInt16 = 3250, state: UInt8 = 1, quiet: UInt16 = 0, error: UInt8 = 0) throws -> NCAck {
        let request = NCFrame(command: .status, transferID: 1)
        let payload = Data([4, error == 0 ? 2 : 0x80, state, error, 0, 0, 0, 0,
                            UInt8(truncatingIfNeeded: vdd), UInt8(vdd >> 8), 0, 0,
                            UInt8(truncatingIfNeeded: quiet), UInt8(quiet >> 8), 0, 0])
        var bytes = try NCFrame(command: .status, transferID: 1, payload: payload).encoded()
        bytes[3] = error == 0 ? 0x80 : 0x81
        let crc = NCCRC.crc16(bytes.prefix(12) + bytes[14..<16])
        bytes[12] = UInt8(truncatingIfNeeded: crc); bytes[13] = UInt8(crc >> 8)
        return try NCAck(data: bytes, request: request)
    }
}
