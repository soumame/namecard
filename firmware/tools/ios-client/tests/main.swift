import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

let check = Data("123456789".utf8)
require(NCProtocol.crc16(check) == 0x29B1, "CRC16")
require(NCProtocol.crc32(check) == 0xCBF4_3926, "CRC32")

let checker = NCProtocol.checkerImage()
require(checker.count == NCProtocol.imageSize, "checker length")
require(checker.prefix(16).allSatisfy { $0 == 0 }, "checker top border")
require(checker[4 * 16] == 0, "checker side border")
require(checker[4 * 16 + 4] == 0xAA, "checker first cell")
require(NCProtocol.crc32(checker) == 0x550F_2D50,
        "checker must match Python/STM32 native image")

let payload = Data([1, 2, 3])
let frame = NCProtocol.frame(type: NCProtocol.data, transferID: 7,
                             sequence: 4, offset: 240, payload: payload)
require(frame.count == 19, "frame length")
require(frame[0] == 0x4E && frame[1] == 0x43, "magic")
require(frame.uint16LE(at: 4) == 7, "transfer ID")
require(frame.uint16LE(at: 6) == 4, "sequence")
require(frame.uint16LE(at: 8) == 240, "offset")
require(frame.uint16LE(at: 10) == 3, "payload length")
require(frame.uint16LE(at: 14) == NCProtocol.crc16(payload), "payload CRC")

var ack = Data(repeating: 0, count: 32)
ack[0] = 0x4E; ack[1] = 0x43; ack[2] = 1; ack[3] = 0x80
ack.putUInt16LE(16, at: 10)
ack[16] = NCProtocol.status; ack[17] = 2; ack[18] = 3
ack.putUInt16LE(5, at: 20); ack.putUInt16LE(4_736, at: 22)
ack.putUInt16LE(3_301, at: 24); ack.putUInt16LE(2_901, at: 26)
ack.putUInt16LE(2_000, at: 28); ack[30] = 0x0F; ack[31] = 1
ack.putUInt16LE(NCProtocol.crc16(Data(ack[16..<32])), at: 14)
var header = Data(ack[0..<12]); header.append(ack[14]); header.append(ack[15])
ack.putUInt16LE(NCProtocol.crc16(header), at: 12)
let decoded = try NCAck(ack)
require(decoded.expectedOffset == 4_736, "ACK offset")
require(decoded.vddMillivolts == 3_301, "ACK VDD")
require(decoded.ehControl == 0x0F, "ACK EH")
print("iOS protocol tests passed")
