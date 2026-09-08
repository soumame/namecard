import Foundation
import XCTest
@testable import NamecardCore

final class TransferRediscoveryTests: XCTestCase {
    private func snapshot(command: NCCommand = .data, uid: Data = Data([1]),
                          executeSent: Bool = false, refreshing: Bool = false,
                          job: TransferJob = .image(Data(repeating: 0xff, count: 4_736), cleanBeforeWrite: false)) -> TransferSnapshot {
        TransferSnapshot(job: job, uid: uid, transferID: 3, expectedSequence: 17, expectedOffset: 2_048,
                         lastAck: nil, unconfirmedCommand: NCFrame(command: command, transferID: 3, sequence: 17, offset: 2_048),
                         executeSent: executeSent, executeAcknowledged: false,
                         refreshMayBeActive: refreshing, nextPattern: 1)
    }

    func testRediscoverySurvivesFourLossesAndRemainsBoundedAndBoundToUID() {
        var budget = TransferRediscovery()
        XCTAssertTrue(budget.reserve(snapshot: snapshot(), now: 10, deadline: 60))
        XCTAssertEqual(budget.uid, Data([1]))
        XCTAssertFalse(budget.reserve(snapshot: snapshot(uid: Data([2])), now: 15, deadline: 60))
        XCTAssertEqual(budget.attempts, 1)
        XCTAssertTrue(budget.reserve(snapshot: snapshot(command: .start), now: 20, deadline: 60))
        for attempt in 3...6 {
            XCTAssertTrue(budget.reserve(snapshot: snapshot(), now: Double(20 + attempt), deadline: 60))
            XCTAssertEqual(budget.attempts, attempt)
        }
        XCTAssertFalse(budget.reserve(snapshot: snapshot(), now: 30, deadline: 60))
    }

    func testNeverRediscoverDuringCommitRefreshOrUnknownWork() {
        for command: NCCommand in [.status, .commit, .execute, .pattern, .ndefWritePrepare] {
            var budget = TransferRediscovery()
            XCTAssertFalse(budget.reserve(snapshot: snapshot(command: command), now: 0, deadline: 60))
        }
        var budget = TransferRediscovery()
        XCTAssertFalse(budget.reserve(snapshot: snapshot(executeSent: true), now: 0, deadline: 60))
        XCTAssertFalse(budget.reserve(snapshot: snapshot(refreshing: true), now: 0, deadline: 60))
        XCTAssertFalse(budget.reserve(snapshot: snapshot(job: .pattern(1)), now: 0, deadline: 60))
        XCTAssertFalse(budget.reserve(snapshot: nil, now: 0, deadline: 60))
        XCTAssertFalse(budget.reserve(snapshot: snapshot(), now: 52, deadline: 60))
        XCTAssertEqual(budget.attempts, 0)
    }
}
