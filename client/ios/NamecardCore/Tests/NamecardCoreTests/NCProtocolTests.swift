import Foundation
import XCTest
@testable import NamecardCore

final class NCProtocolTests: XCTestCase {
    private var request: NCFrame { NCFrame(command: .data, transferID: 0x1234, sequence: 7, offset: 240, payload: Data([0x10, 0x20, 0x30])) }

    func testCRCsMatchStandardCheckVectorsAndAndroidFrame() throws {
        XCTAssertEqual(NCCRC.crc16(Data("123456789".utf8)), 0x29b1)
        XCTAssertEqual(NCCRC.crc32(Data("123456789".utf8)), 0xcbf43926)
        XCTAssertEqual(try request.encoded(), Data([0x4e,0x43,0x01,0x02,0x34,0x12,0x07,0x00,0xf0,0x00,0x03,0x00,0x16,0xb8,0x4a,0xbf,0x10,0x20,0x30]))
        XCTAssertEqual(try NCFrame(command: .data, transferID: 1, payload: Data(repeating: 0, count: 240)).encoded().count, 256)
        XCTAssertThrowsError(try NCFrame(command: .data, transferID: 1, payload: Data(repeating: 0, count: 241)).encoded())
    }

    func testMetadataLayoutAndCRC() throws {
        let metadata = try NCMetadata.image(Data(repeating: 0, count: 4_736), batchClean: true)
        XCTAssertEqual(metadata.prefix(8), Data([0x28,1,0x80,0,0x80,0x12,1,1]))
        // IEEE CRC32 of 4,736 zero bytes, independently generated with zlib.
        XCTAssertEqual(metadata[8..<12], Data([0x0f,0x03,0xb0,0x91]))
        XCTAssertEqual(metadata.suffix(4), Data([1,0,0,0]))
        XCTAssertThrowsError(try NCMetadata.image(Data(repeating: 0, count: 9_472), batchClean: false))
    }

    func testACKProgressAndCapabilities() throws {
        let ack = try NCAck(data: ackBytes(), request: request)
        XCTAssertEqual(ack.transferID, 0x1234)
        XCTAssertEqual(ack.expectedSequence, 8)
        XCTAssertEqual(ack.expectedOffset, 243)
        XCTAssertEqual(ack.vddMV, 3_200)
        XCTAssertTrue(ack.supportsBatchClean && ack.hasPendingImage && ack.currentDisplayIsGray && ack.hasGrayPlane0Pending)
        XCTAssertNoThrow(try ack.requireSuccess())
    }

    func testRejectsCorruptUnrelatedAndStaleACKs() throws {
        var corrupted = ackBytes(); corrupted[24] ^= 1
        XCTAssertThrowsError(try NCAck(data: corrupted, request: request))
        XCTAssertThrowsError(try NCAck(data: ackBytes().dropLast(), request: request))
        let mutations: [(Int, UInt8)] = [(0,0),(2,2),(3,0x82),(4,0),(6,8),(8,0),(10,15),(16,1),(17,9),(18,8),(20,7),(22,242)]
        for (index, value) in mutations {
            var bytes = ackBytes(); bytes[index] = value; repair(&bytes)
            XCTAssertThrowsError(try NCAck(data: bytes, request: request), "offset \(index)")
        }
    }

    func testRejectionCarriesRecoveryOffsetButCannotSucceed() throws {
        var bytes = ackBytes(); bytes[3] = 0x81; bytes[17] = 0x80; bytes[19] = 8
        bytes[20] = 3; bytes[8] = 128; bytes[22] = 128; repair(&bytes)
        let ack = try NCAck(data: bytes, request: request)
        XCTAssertEqual(ack.expectedSequence, 3)
        XCTAssertThrowsError(try ack.requireSuccess())
    }

    func testExecuteChargingDoesNotAdvanceSequence() throws {
        let execute = NCFrame(command: .execute, transferID: 0x1234, sequence: 7, offset: 4_736)
        var bytes = ackBytes(); bytes[16] = 5; bytes[17] = 3; bytes[18] = 2; bytes[20] = 7
        bytes[8] = 0x80; bytes[9] = 0x12; bytes[22] = 0x80; bytes[23] = 0x12; repair(&bytes)
        XCTAssertNoThrow(try NCAck(data: bytes, request: execute))
        bytes[20] = 8; repair(&bytes)
        XCTAssertThrowsError(try NCAck(data: bytes, request: execute))
    }

    private func ackBytes() -> Data {
        var bytes = Data([0x4e,0x43,1,0x80,0x34,0x12,7,0,243,0,16,0,0,0,0,0,2,0,1,0,8,0,243,0,0x80,0x0c,0x80,0x0b,0,0,0,0xcc])
        repair(&bytes)
        return bytes
    }

    private func repair(_ bytes: inout Data) {
        let payloadCRC = NCCRC.crc16(bytes[16..<32])
        bytes[14] = UInt8(truncatingIfNeeded: payloadCRC); bytes[15] = UInt8(payloadCRC >> 8)
        let headerCRC = NCCRC.crc16(bytes.prefix(12) + bytes[14..<16])
        bytes[12] = UInt8(truncatingIfNeeded: headerCRC); bytes[13] = UInt8(headerCRC >> 8)
    }
}
