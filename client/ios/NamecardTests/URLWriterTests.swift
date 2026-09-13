import Foundation
import CoreNFC
import XCTest
import NamecardCore
@testable import Namecard

final class URLWriterTests: XCTestCase {
    @MainActor
    func testServiceRestoresPendingClearAfterRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = URLJournalStore(file: directory.appendingPathComponent("url-write-journal.json"))
        defer { clean(store) }
        try store.save(URLWriteJournal(uid: Data([1,2,3,4]), url: "", message: URLCodec.emptyNDEFMessage, clearsURL: true))
        let service = NFCService(directory: directory)
        XCTAssertEqual(service.recoveryURL, .clear)
    }

    func testClearWritesAnEmptyRecordAndAllowsURLToBeSetAgain() async throws {
        let store = makeStore()
        defer { clean(store) }
        let tag = try MockURLTag(formatted: true)
        try await clear(tag, store)
        XCTAssertEqual(tag.events, ["enable", "prepare", "disable", "read", "ndefStatus", "writeNDEF", "read", "enable"])
        let bytes = try XCTUnwrap(URLCodec.type5NDEF(in: tag.memory))
        let message = try XCTUnwrap(NFCNDEFMessage(data: bytes))
        XCTAssertEqual(message.records.count, 1)
        let record = try XCTUnwrap(message.records.first)
        XCTAssertEqual(record.typeNameFormat, .empty)
        XCTAssertTrue(record.type.isEmpty)
        XCTAssertTrue(record.identifier.isEmpty)
        XCTAssertTrue(record.payload.isEmpty)
        XCTAssertNil(record.wellKnownTypeURIPayload())
        XCTAssertNil(try store.load())

        try await clear(tag, store) // Clearing an already cleared card is safe.
        try await write(tag, store)
        XCTAssertEqual(try URLCodec.type5NDEF(in: tag.memory), try URLCodec.ndefMessage(for: targetURL))
    }

    func testClearFailuresKeepOperationForRecovery() async throws {
        for failure in ["write", "mismatch", "restore"] {
            let store = makeStore()
            defer { clean(store) }
            let tag = try MockURLTag(formatted: true)
            tag.failWrite = failure == "write"
            tag.ignoreWrite = failure == "mismatch"
            tag.failRestore = failure == "restore"
            await expectFailure { try await self.clear(tag, store) }
            XCTAssertEqual(try store.load()?.operation, .clear, failure)
            XCTAssertEqual(tag.events.last, "enable", failure)

            tag.failWrite = false
            tag.ignoreWrite = false
            tag.failRestore = false
            try await URLWriter.write(try XCTUnwrap(store.load()).operation, mailbox: tag, store: store,
                                      sleep: { _ in }, progress: { _ in })
            XCTAssertEqual(try URLCodec.type5NDEF(in: tag.memory), URLCodec.emptyNDEFMessage)
            XCTAssertNil(try store.load())
        }
    }

    func testPendingClearCannotBeReplacedOrAppliedToAnotherCard() async throws {
        let store = makeStore()
        defer { clean(store) }
        let tag = try MockURLTag(formatted: true)
        tag.failWrite = true
        await expectFailure { try await self.clear(tag, store) }
        tag.events = []
        await expectFailure { try await self.write(tag, store) }
        XCTAssertTrue(tag.events.isEmpty)
        let other = try MockURLTag(formatted: true, identifier: Data([9,9]))
        await expectFailure { try await self.clear(other, store) }
        XCTAssertTrue(other.events.isEmpty)
        XCTAssertEqual(try store.load()?.operation, .clear)
    }

    func testClearRefusesProtectedOrUnknownMemoryWithoutWriting() async throws {
        for status in [URLMemoryStatus.readOnly, .notSupported] {
            let store = makeStore()
            defer { clean(store) }
            let tag = try MockURLTag(formatted: true)
            let original = tag.memory
            tag.overriddenStatus = status
            await expectFailure { try await self.clear(tag, store) }
            XCTAssertEqual(tag.memory, original)
            XCTAssertFalse(tag.events.contains("writeNDEF"))
            XCTAssertFalse(tag.events.contains(where: { $0.hasPrefix("block") }))
            XCTAssertEqual(tag.events.last, "enable")
            XCTAssertNil(try store.load())
        }
    }

    func testClearBlankCardResumesInterruptedFormatting() async throws {
        let store = makeStore()
        defer { clean(store) }
        let tag = try MockURLTag(formatted: false)
        tag.failBlockNumber = 2
        await expectFailure { try await self.clear(tag, store) }
        XCTAssertEqual(try store.load()?.operation, .clear)
        XCTAssertNotNil(try store.load()?.writes)
        tag.failBlockNumber = nil
        try await clear(tag, store)
        XCTAssertEqual(try URLCodec.type5NDEF(in: tag.memory), URLCodec.emptyNDEFMessage)
        XCTAssertNil(try store.load())
    }

    func testLegacyURLJournalStillResumesAndCannotBeClearedInstead() async throws {
        let store = makeStore()
        defer { clean(store) }
        let tag = try MockURLTag(formatted: true)
        let bytes = try URLCodec.ndefMessage(for: targetURL)
        // This JSON has exactly the fields written by the previous app version.
        let legacy = try JSONSerialization.data(withJSONObject: [
            "uid": tag.identifier.base64EncodedString(), "url": targetURL,
            "message": bytes.base64EncodedString(),
        ])
        try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try legacy.write(to: store.file)
        XCTAssertEqual(try store.load()?.operation, .set(targetURL))
        await expectFailure { try await self.clear(tag, store) }
        XCTAssertTrue(tag.events.isEmpty)
        try await write(tag, store)
        XCTAssertEqual(try URLCodec.type5NDEF(in: tag.memory), bytes)
        XCTAssertNil(try store.load())
    }

    func testPrepareDisableWriteVerifyRestoreOrdering() async throws {
        let store = makeStore()
        defer { clean(store) }
        let tag = try MockURLTag(formatted: true)
        try await write(tag, store)
        XCTAssertEqual(tag.events, ["enable", "prepare", "disable", "read", "ndefStatus", "writeNDEF", "read", "enable"])
        XCTAssertEqual(try URLCodec.type5NDEF(in: tag.memory), try URLCodec.ndefMessage(for: targetURL))
        XCTAssertNil(try store.load())
    }

    func testUnsupportedPrepareNeverTouchesEEPROM() async throws {
        let store = makeStore()
        defer { clean(store) }
        let tag = try MockURLTag(formatted: true)
        tag.unsupportedPrepare = true
        await expectFailure { try await self.write(tag, store) }
        XCTAssertEqual(tag.events, ["enable", "prepare", "enable"])
        XCTAssertNil(try store.load())
    }

    func testWriteFailureRestoresMailboxAndKeepsJournal() async throws {
        let store = makeStore()
        defer { clean(store) }
        let tag = try MockURLTag(formatted: true)
        tag.failWrite = true
        await expectFailure { try await self.write(tag, store) }
        XCTAssertEqual(tag.events.last, "enable")
        XCTAssertEqual(try store.load()?.uid, tag.identifier)
        XCTAssertFalse(tag.events.suffix(2).contains("read"))
    }

    func testPreWriteRefusalDoesNotTrapOtherOperationsBehindJournal() async throws {
        for status in [URLMemoryStatus.readOnly, .readWrite(1), .notSupported] {
            let store = makeStore()
            defer { clean(store) }
            let tag = try MockURLTag(formatted: true)
            tag.overriddenStatus = status
            await expectFailure { try await self.write(tag, store) }
            XCTAssertFalse(tag.events.contains("writeNDEF"))
            XCTAssertFalse(tag.events.contains(where: { $0.hasPrefix("block") }))
            XCTAssertEqual(tag.events.last, "enable")
            XCTAssertNil(try store.load(), "No EEPROM mutation and successful Mailbox restoration need no recovery lock")
        }
        let store = makeStore()
        defer { clean(store) }
        let tag = try MockURLTag(formatted: true)
        tag.overriddenStatus = .readOnly
        tag.failRestore = true
        await expectFailure { try await self.write(tag, store) }
        XCTAssertNotNil(try store.load(), "A failed Mailbox restoration still requires recovery")
    }

    func testVerificationMismatchAndRestoreFailureDoNotClearJournal() async throws {
        for failure in ["mismatch", "restore"] {
            let store = makeStore()
            defer { clean(store) }
            let tag = try MockURLTag(formatted: true)
            tag.ignoreWrite = failure == "mismatch"
            tag.failRestore = failure == "restore"
            await expectFailure { try await self.write(tag, store) }
            XCTAssertNotNil(try store.load(), failure)
            XCTAssertEqual(tag.events.last, "enable", failure)
        }
    }

    func testPersistenceFailureAfterPrepareStillRestoresMailbox() async throws {
        let store = makeStore()
        defer { clean(store) }
        let parent = store.file.deletingLastPathComponent()
        try Data([1]).write(to: parent)
        let tag = try MockURLTag(formatted: true)
        await expectFailure { try await self.write(tag, store) }
        XCTAssertEqual(tag.events, ["enable", "prepare", "enable"])
    }

    func testBlankInitializationResumesAfterPowerLossOnlyOnSameUID() async throws {
        let store = makeStore()
        defer { clean(store) }
        let tag = try MockURLTag(formatted: false)
        tag.failBlockNumber = 3
        await expectFailure { try await self.write(tag, store) }
        let prior = try XCTUnwrap(store.load())
        XCTAssertNotNil(prior.writes)
        XCTAssertEqual(try URLCodec.type5NDEF(in: tag.memory), Data())

        let other = try MockURLTag(formatted: false, identifier: Data([9,9]))
        await expectFailure { try await self.write(other, store) }
        XCTAssertTrue(other.events.isEmpty)
        XCTAssertEqual(try store.load()?.uid, tag.identifier)

        tag.failBlockNumber = nil
        tag.events = []
        try await write(tag, store)
        XCTAssertEqual(try URLCodec.type5NDEF(in: tag.memory), try URLCodec.ndefMessage(for: targetURL))
        XCTAssertEqual(tag.events.last, "enable")
        XCTAssertNil(try store.load())
    }

    func testChangedMemoryAndNewProtectionPreventRecoveryWrites() async throws {
        for failure in ["changed", "protected"] {
            let store = makeStore()
            defer { clean(store) }
            let tag = try MockURLTag(formatted: false)
            tag.failBlockNumber = 3
            await expectFailure { try await self.write(tag, store) }
            tag.failBlockNumber = nil
            tag.events = []
            if failure == "changed" { tag.memory[511] = 0x77 }
            else { tag.allBlocksWritable = false }
            await expectFailure { try await self.write(tag, store) }
            XCTAssertFalse(tag.events.contains(where: { $0.hasPrefix("block") }), failure)
            XCTAssertNotNil(try store.load(), failure)
            XCTAssertEqual(tag.events.last, "enable", failure)
        }
    }

    func testCorruptedJournalPlanCannotOverwriteUnrelatedMemory() async throws {
        let store = makeStore()
        defer { clean(store) }
        let tag = try MockURLTag(formatted: false)
        tag.failBlockNumber = 3
        await expectFailure { try await self.write(tag, store) }
        var journal = try XCTUnwrap(store.load())
        // An arbitrary extra write would previously pass validateReplay because
        // its original bytes still matched. Only the canonical plan may replay.
        journal.writes?.append(Type5BlockWrite(block: 127, bytes: Data([9,8,7,6])))
        try store.save(journal)
        tag.events = []
        tag.failBlockNumber = nil
        await expectFailure { try await self.write(tag, store) }
        XCTAssertFalse(tag.events.contains(where: { $0.hasPrefix("block") }))
        XCTAssertEqual(tag.memory.suffix(4), Data(repeating: 0, count: 4))
        XCTAssertNotNil(try store.load())
    }

    private let targetURL = "https://example.com/namecard"
    private func clear(_ tag: MockURLTag, _ store: URLJournalStore) async throws {
        try await URLWriter.write(.clear, mailbox: tag, store: store, sleep: { _ in }, progress: { _ in })
    }
    private func write(_ tag: MockURLTag, _ store: URLJournalStore) async throws {
        try await URLWriter.write(.set(targetURL), mailbox: tag, store: store, sleep: { _ in }, progress: { _ in })
    }
    private func makeStore() -> URLJournalStore {
        URLJournalStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json"))
    }
    private func clean(_ store: URLJournalStore) { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
    private func expectFailure(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected failure", file: file, line: line) }
        catch { }
    }
}

/// A serial NFC tag model with real NC ACK serialization and mutable EEPROM.
private final class MockURLTag: URLTagTransport, @unchecked Sendable {
    let identifier: Data
    var memory = Data(repeating: 0, count: 512)
    var events: [String] = []
    var unsupportedPrepare = false
    var failWrite = false
    var ignoreWrite = false
    var failRestore = false
    var failBlockNumber: Int?
    var allBlocksWritable = true
    var overriddenStatus: URLMemoryStatus?
    private let formatted: Bool
    private var prepared = false

    init(formatted: Bool, identifier: Data = Data([1,2,3,4])) throws {
        self.formatted = formatted
        self.identifier = identifier
        if formatted { try putMessage(URLCodec.ndefMessage(for: "https://old.example.com")) }
    }
    func checkConnection() throws { }
    func setEnabled(_ enabled: Bool) async throws {
        events.append(enabled ? "enable" : "disable")
        if enabled && prepared && failRestore { throw AppFailure("restore failure") }
    }
    func exchange(_ frame: NCFrame, timeout: TimeInterval) async throws -> NCAck {
        XCTAssertEqual(frame.type, NCCommand.ndefWritePrepare.rawValue)
        events.append("prepare")
        prepared = true
        var raw = Data(repeating: 0, count: 32)
        raw[0] = 0x4e; raw[1] = 0x43; raw[2] = 1; raw[3] = unsupportedPrepare ? 0x81 : 0x80
        raw[4] = UInt8(truncatingIfNeeded: frame.transferID); raw[5] = UInt8(frame.transferID >> 8)
        raw[6] = UInt8(truncatingIfNeeded: frame.sequence); raw[7] = UInt8(frame.sequence >> 8)
        raw[10] = 16; raw[16] = frame.type; raw[17] = unsupportedPrepare ? 0x80 : 2
        raw[18] = 6; raw[19] = unsupportedPrepare ? 6 : 0
        let payloadCRC = NCCRC.crc16(raw[16..<32])
        raw[14] = UInt8(truncatingIfNeeded: payloadCRC); raw[15] = UInt8(payloadCRC >> 8)
        let headerCRC = NCCRC.crc16(raw.prefix(12) + raw[14..<16])
        raw[12] = UInt8(truncatingIfNeeded: headerCRC); raw[13] = UInt8(headerCRC >> 8)
        return try NCAck(data: raw, request: frame)
    }
    func readMemory() async throws -> Data { events.append("read"); return memory }
    func blankIdentity() async throws -> Type5Identity {
        events.append("identity")
        return identity(writable: allBlocksWritable)
    }
    func ndefStatus() async throws -> URLMemoryStatus { events.append("ndefStatus"); return overriddenStatus ?? (formatted ? .readWrite(480) : .notSupported) }
    func writeMessage(_ message: Data) async throws {
        events.append("writeNDEF")
        if failWrite { throw AppFailure("write failure") }
        if !ignoreWrite { try putMessage(message) }
    }
    func writeBlock(_ write: Type5BlockWrite) async throws {
        events.append("block\(write.block)")
        if write.block == failBlockNumber { throw AppFailure("power loss") }
        memory.replaceSubrange((write.block * 4)..<(write.block * 4 + 4), with: write.bytes)
    }
    private func putMessage(_ message: Data) throws {
        for write in try URLCodec.blankType5WritePlan(memory: Data(repeating: 0, count: 512), message: message, identity: identity(writable: true)) {
            memory.replaceSubrange((write.block * 4)..<(write.block * 4 + 4), with: write.bytes)
        }
    }
    private func identity(writable: Bool) -> Type5Identity {
        Type5Identity(manufacturerCode: 2, icReference: 0x24, blockCount: 128, blockSize: 4, allBlocksWritable: writable)
    }
}
