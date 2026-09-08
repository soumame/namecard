import Foundation
import XCTest
@testable import NamecardCore

final class URLCodecTests: XCTestCase {
    private let identity = Type5Identity(manufacturerCode: 2, icReference: 0x24, blockCount: 128, blockSize: 4, allBlocksWritable: true)

    func testAndroidURLNormalizationCases() throws {
        XCTAssertEqual(try URLCodec.normalize(" example.com/namecard \n"), "https://example.com/namecard")
        XCTAssertEqual(try URLCodec.normalize("http://example.com/名刺"), "http://example.com/%E5%90%8D%E5%88%BA")
        XCTAssertEqual(try URLCodec.normalize("example.com:8080/profile"), "https://example.com:8080/profile")
        XCTAssertEqual(try URLCodec.normalize("HTTP://EXAMPLE.COM/a%2f"), "HTTP://EXAMPLE.COM/a%2f")
        XCTAssertEqual(try URLCodec.normalize("https://[::1]:8080/a"), "https://[::1]:8080/a")
        XCTAssertEqual(try URLCodec.normalize("https://example.com/?x=[1]#a[1]"), "https://example.com/?x=[1]#a[1]")
        XCTAssertEqual(try URLCodec.normalize("https://example.com:99999"), "https://example.com:99999")
        for url in ["", "mailto:test@example.com", "https://example.com/a b", "https://@", "https://example.com/%zz", "https://example.com/a[1]", "https://.example.com", "https://exa_mple.com", "https://example.com/\u{1}", "https://foo.123", "https://123.456", "https://example.com:foo", "https://example.com:999999999999999999999"] {
            XCTAssertThrowsError(try URLCodec.normalize(url), url)
        }
    }

    func testURICompressionAndNDEFSizeLimit() throws {
        XCTAssertEqual(try URLCodec.ndefMessage(for: "https://www.example.com"), Data([0xd1,1,12,0x55,2]) + Data("example.com".utf8))
        XCTAssertEqual(try URLCodec.ndefMessage(for: "http://example.com"), Data([0xd1,1,12,0x55,3]) + Data("example.com".utf8))
        XCTAssertEqual(try URLCodec.ndefMessage(for: "https://e.com/" + String(repeating: "x", count: 466)).count, 480)
        XCTAssertThrowsError(try URLCodec.ndefMessage(for: "https://e.com/" + String(repeating: "x", count: 467)))
        let short = try URLCodec.ndefMessage(for: "https://e.com/" + String(repeating: "x", count: 248))
        XCTAssertEqual(short.prefix(4), Data([0xd1, 1, 255, 0x55]))
        let long = try URLCodec.ndefMessage(for: "https://e.com/" + String(repeating: "x", count: 249))
        XCTAssertEqual(long.prefix(7), Data([0xc1, 1, 0, 0, 1, 0, 0x55]))
    }

    func testTLVLengthBoundaryAndFinalWriteCommitsLength() throws {
        for length in [254,255,480] {
            let message = Data((0..<length).map { UInt8(truncatingIfNeeded: $0) })
            let writes = try URLCodec.blankType5WritePlan(memory: Data(repeating: 0, count: 512), message: message, identity: identity)
            XCTAssertEqual(writes.last?.block, 1)
            var memory = Data(repeating: 0, count: 512)
            for write in writes.dropLast() { memory.replaceSubrange((write.block * 4)..<(write.block * 4 + 4), with: write.bytes) }
            XCTAssertEqual(try URLCodec.type5NDEF(in: memory), Data())
            let last = try XCTUnwrap(writes.last)
            memory.replaceSubrange(4..<8, with: last.bytes)
            XCTAssertEqual(try URLCodec.type5NDEF(in: memory), message)
            XCTAssertEqual(memory[5], length < 255 ? UInt8(length) : 255)
        }
        XCTAssertThrowsError(try URLCodec.blankType5WritePlan(memory: Data(repeating: 0, count: 512), message: Data(repeating: 0, count: 481), identity: identity))
    }

    func testUnknownProtectedAndNonblankTagsAreNeverInitialized() throws {
        let message = try URLCodec.ndefMessage(for: "example.com")
        for fill: UInt8 in [1,255] { XCTAssertThrowsError(try URLCodec.blankType5WritePlan(memory: Data(repeating: fill, count: 512), message: message, identity: identity)) }
        let invalid = [Type5Identity(manufacturerCode: 3, icReference: 0x24, blockCount: 128, blockSize: 4, allBlocksWritable: true), Type5Identity(manufacturerCode: 2, icReference: 0x26, blockCount: 128, blockSize: 4, allBlocksWritable: true), Type5Identity(manufacturerCode: 2, icReference: 0x24, blockCount: 128, blockSize: 4, allBlocksWritable: false)]
        for identity in invalid { XCTAssertThrowsError(try URLCodec.blankType5WritePlan(memory: Data(repeating: 0, count: 512), message: message, identity: identity)) }
    }

    func testParserSkipsUnknownTLVsAndRejectsTruncation() throws {
        let short = Data([0xe1,0x40,0x40,0,0,0xfd,2,0xaa,0xbb,3,2,0xd1,0x55,0xfe])
        XCTAssertEqual(try URLCodec.type5NDEF(in: short), Data([0xd1,0x55]))
        let message = Data(repeating: 0x55, count: 260)
        let extended = Data([0xe2,0x40,0,0,0,0,4,0,3,255,1,4]) + message
        XCTAssertEqual(try URLCodec.type5NDEF(in: extended), message)
        XCTAssertThrowsError(try URLCodec.type5NDEF(in: Data([0xe1,0x40,0x40,0,3,8,1])))
        XCTAssertThrowsError(try URLCodec.type5NDEF(in: Data([0xe1,0x40,0x40,0,3,255,1])))
        XCTAssertNil(try URLCodec.type5NDEF(in: Data(repeating: 0, count: 512)))
    }
}
