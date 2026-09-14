import CoreNFC
import Foundation
import NamecardCore
import XCTest
@testable import Namecard

private actor URLTestClock: TransferClock {
    var time: TimeInterval = 0
    func now() -> TimeInterval { time }
    func sleep(seconds: TimeInterval) { time += seconds }
}

private actor StartupFixture {
    var energies: [UInt8]
    var enabled = false
    var enables = 0
    var energyReads = 0
    var unavailable = 0
    var failure: Error?
    init(_ energies: [UInt8], unavailable: Int = 0, failure: Error? = nil) {
        self.energies = energies; self.unavailable = unavailable; self.failure = failure
    }
    func energy() throws -> UInt8 {
        energyReads += 1
        if let failure { throw failure }
        if unavailable > 0 {
            unavailable -= 1
            throw MailboxAvailabilityError.unavailable("AD ISO15693=10")
        }
        return energies.count > 1 ? energies.removeFirst() : energies[0]
    }
    func control() -> UInt8 { enabled ? 1 : 0 }
    func enable() { enables += 1; enabled = true }
}

private actor MemoryFixture {
    let memory: Data
    var blocks: [Int] = []
    var transientFailures: Int
    init(_ memory: Data, transientFailures: Int = 0) {
        self.memory = memory; self.transientFailures = transientFailures
    }
    func read(_ block: Int) throws -> Data {
        blocks.append(block)
        if transientFailures > 0 {
            transientFailures -= 1
            throw ST25Mailbox.transportError(NSError(domain: NFCErrorDomain,
                code: NFCReaderError.Code.readerTransceiveErrorTagResponseError.rawValue,
                userInfo: [NFCISO15693TagResponseErrorKey: NSNumber(value: 0x0f)]))
        }
        let start = block * 4
        guard start + 4 <= memory.count else { throw URLCodecError.malformedType5 }
        return memory.subdata(in: start..<(start + 4))
    }
}

final class URLTransportTests: XCTestCase {
    private func start(_ fixture: StartupFixture, clock: URLTestClock, deadline: TimeInterval = 30) async throws {
        try await URLMailboxStartup.enable(deadline: deadline, clock: clock,
            readEnergy: { try await fixture.energy() }, readControl: { await fixture.control() },
            enableMailbox: { await fixture.enable() })
    }

    func testStartupWaitsForVCCBeforeEnablingMailbox() async throws {
        let fixture = StartupFixture([0, 0, 8])
        let clock = URLTestClock()
        try await start(fixture, clock: clock)
        let enables = await fixture.enables
        let reads = await fixture.energyReads
        let time = await clock.now()
        XCTAssertEqual(enables, 1)
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(time, 2.025, accuracy: 0.0001)
    }

    func testStartupRetriesUnavailableRegistersButNotConnectionLoss() async throws {
        let fixture = StartupFixture([8], unavailable: 2)
        try await start(fixture, clock: URLTestClock())
        let reads = await fixture.energyReads
        XCTAssertEqual(reads, 3)

        for failure: Error in [MailboxTransportError.connectionLost("isAvailable=false"), CancellationError(), AppFailure("invalid register length")] {
            let lost = StartupFixture([8], failure: failure)
            do { try await start(lost, clock: URLTestClock()); XCTFail("Terminal error retried") }
            catch { }
            let lostReads = await lost.energyReads
            let enables = await lost.enables
            XCTAssertEqual(lostReads, 1)
            XCTAssertEqual(enables, 0)
        }
    }

    func testStartupHonorsBothEightSecondWindowAndSessionDeadline() async {
        for deadline in [2.5, 30.0] {
            let clock = URLTestClock()
            let fixture = StartupFixture([0])
            do { try await start(fixture, clock: clock, deadline: deadline); XCTFail("Unpowered startup succeeded") }
            catch { }
            let time = await clock.now()
            let enables = await fixture.enables
            XCTAssertEqual(time, min(8, deadline), accuracy: 0.0001)
            XCTAssertEqual(enables, 0)
        }
    }

    func testShortNDEFReadStopsBeforeUnusedMemory() async throws {
        let message = try URLCodec.ndefMessage(for: "https://example.com")
        let fixture = MemoryFixture(padded(Data([0xe1, 0x40, 0x40, 0, 3, UInt8(message.count)]) + message + Data([0xfe])))
        let actual = try await URLNDEFReader.read { try await fixture.read($0) }
        XCTAssertEqual(actual, message)
        let blocks = await fixture.blocks
        XCTAssertEqual(blocks, Array(0..<((6 + message.count + 3) / 4)))
        XCTAssertLessThan(blocks.count, 10)
    }

    func testExtendedCCAndPrecedingTLVsRemainVerifiable() async throws {
        let message = try URLCodec.ndefMessage(for: "https://example.com/" + String(repeating: "a", count: 280))
        var memory = Data([0xe2, 0x40, 0, 0, 0, 0, 0x40, 0])
        memory.append(contentsOf: [0, 0, 1, 3, 0x11, 0x22, 0x33, 3, 255, UInt8(message.count >> 8), UInt8(message.count & 255)])
        memory.append(message)
        memory.append(0xfe)
        let fixture = MemoryFixture(padded(memory))
        let actual = try await URLNDEFReader.read { try await fixture.read($0) }
        XCTAssertEqual(actual, message)
    }

    func testEmptyRecordAndMalformedLengthsCannotReadPastTag() async throws {
        let fixture = MemoryFixture(padded(Data([0xe1, 0x40, 0x40, 0, 3, 3, 0xd0, 0, 0, 0xfe])))
        let actual = try await URLNDEFReader.read { try await fixture.read($0) }
        XCTAssertEqual(actual, URLCodec.emptyNDEFMessage)
        let invalid = MemoryFixture(padded(Data([0xe1, 0x40, 0x40, 0, 3, 255, 0xff, 0xff])))
        do {
            _ = try await URLNDEFReader.read { try await invalid.read($0) }
            XCTFail("Oversized TLV accepted")
        } catch { XCTAssertTrue(error is URLCodecError) }
        let blocks = await invalid.blocks
        XCTAssertEqual(blocks, [0, 1])
    }

    func testTransientBlockReadRecoversAndConnectionLossRemainsTyped() async throws {
        let fixture = MemoryFixture(Data([1, 2, 3, 4]), transientFailures: 2)
        let data = try await NFCReadRetry.read(deadline: 10, clock: URLTestClock()) { try await fixture.read(0) }
        XCTAssertEqual(data, Data([1, 2, 3, 4]))
        let blocks = await fixture.blocks
        XCTAssertEqual(blocks, [0, 0, 0])
        let error = ST25Mailbox.transportError(NSError(domain: NFCErrorDomain,
            code: NFCReaderError.Code.readerTransceiveErrorTagConnectionLost.rawValue))
        guard case MailboxTransportError.connectionLost = error else { return XCTFail("Lost tag is not rediscoverable") }
    }

    func testURLRediscoveryRejectsOtherUIDAndHasBoundedAttemptsAndTime() {
        var recovery = URLRediscovery()
        XCTAssertTrue(recovery.reserve(uid: Data([1]), now: 0, deadline: 60))
        XCTAssertFalse(recovery.accepts(Data([2])))
        XCTAssertFalse(recovery.reserve(uid: Data([2]), now: 1, deadline: 60))
        XCTAssertTrue(recovery.reserve(uid: Data([1]), now: 2, deadline: 60))
        XCTAssertTrue(recovery.reserve(uid: Data([1]), now: 3, deadline: 60))
        XCTAssertFalse(recovery.reserve(uid: Data([1]), now: 4, deadline: 60))
        var nearDeadline = URLRediscovery()
        XCTAssertFalse(nearDeadline.reserve(uid: Data([1]), now: 47, deadline: 60))
        XCTAssertNil(nearDeadline.uid)
    }

    private func padded(_ bytes: Data) -> Data { bytes + Data(repeating: 0, count: 512 - bytes.count) }
}
