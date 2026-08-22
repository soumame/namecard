import Foundation

enum NCProtocol {
    static let imageWidth = 296
    static let imageHeight = 128
    static let imageSize = 4_736
    static let frameHeaderSize = 16
    static let ackFrameSize = 32
    static let dataPayloadSize = 220

    static let start: UInt8 = 0x01
    static let data: UInt8 = 0x02
    static let commit: UInt8 = 0x03
    static let status: UInt8 = 0x04
    static let execute: UInt8 = 0x05
    static let pattern: UInt8 = 0x06

    static func frame(type: UInt8, transferID: UInt16, sequence: UInt16,
                      offset: UInt16, payload: Data = Data()) -> Data {
        precondition(payload.count <= 240)
        var raw = Data(repeating: 0, count: frameHeaderSize + payload.count)
        raw[0] = Character("N").asciiValue!
        raw[1] = Character("C").asciiValue!
        raw[2] = 1
        raw[3] = type
        raw.putUInt16LE(transferID, at: 4)
        raw.putUInt16LE(sequence, at: 6)
        raw.putUInt16LE(offset, at: 8)
        raw.putUInt16LE(UInt16(payload.count), at: 10)
        raw.putUInt16LE(crc16(payload), at: 14)
        raw.replaceSubrange(frameHeaderSize..<raw.count, with: payload)

        var headerInput = Data(raw[0..<12])
        headerInput.append(raw[14])
        headerInput.append(raw[15])
        raw.putUInt16LE(crc16(headerInput), at: 12)
        return raw
    }

    static func imageMetadata(for image: Data) -> Data {
        precondition(image.count == imageSize)
        var value = Data(repeating: 0, count: 16)
        value.putUInt16LE(UInt16(imageWidth), at: 0)
        value.putUInt16LE(UInt16(imageHeight), at: 2)
        value.putUInt16LE(UInt16(imageSize), at: 4)
        value[6] = 1                 // EPD_NATIVE_1BPP
        value[7] = 1                 // full-screen Partial
        value.putUInt32LE(crc32(image), at: 8)
        return value
    }

    static func checkerImage() -> Data {
        var image = Data(repeating: 0xFF, count: imageSize)
        for longAxis in 0..<imageWidth {
            for byteInRow in 0..<(imageHeight / 8) {
                let border = longAxis < 4 || longAxis >= imageWidth - 4
                    || byteInRow == 0 || byteInRow == imageHeight / 8 - 1
                if border {
                    image[longAxis * (imageHeight / 8) + byteInRow] = 0x00
                } else if ((longAxis / 24) + (byteInRow / 2)) % 2 == 0 {
                    image[longAxis * (imageHeight / 8) + byteInRow] = 0xAA
                }
            }
        }
        return image
    }

    static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

struct NCAck {
    let code: UInt8
    let state: UInt8
    let error: UInt8
    let expectedSequence: UInt16
    let expectedOffset: UInt16
    let vddMillivolts: UInt16
    let minimumVDDMillivolts: UInt16
    let quietMilliseconds: UInt16
    let ehControl: UInt8
    let mailboxEnabled: Bool

    init(_ raw: Data) throws {
        guard raw.count == NCProtocol.ackFrameSize,
              raw[0] == Character("N").asciiValue!,
              raw[1] == Character("C").asciiValue!,
              raw[2] == 1 else {
            throw NCClientError.invalidAck("length/magic/version")
        }
        let payloadLength = Int(raw.uint16LE(at: 10))
        guard payloadLength == 16 else {
            throw NCClientError.invalidAck("payload length \(payloadLength)")
        }
        var headerInput = Data(raw[0..<12])
        headerInput.append(raw[14])
        headerInput.append(raw[15])
        guard NCProtocol.crc16(headerInput) == raw.uint16LE(at: 12),
              NCProtocol.crc16(Data(raw[16..<32])) == raw.uint16LE(at: 14) else {
            throw NCClientError.invalidAck("CRC")
        }
        code = raw[17]
        state = raw[18]
        error = raw[19]
        expectedSequence = raw.uint16LE(at: 20)
        expectedOffset = raw.uint16LE(at: 22)
        vddMillivolts = raw.uint16LE(at: 24)
        minimumVDDMillivolts = raw.uint16LE(at: 26)
        quietMilliseconds = raw.uint16LE(at: 28)
        ehControl = raw[30]
        mailboxEnabled = raw[31] != 0
    }

    func requireSuccess() throws {
        if code == 0x80 || error != 0 {
            throw NCClientError.firmware(Int(error), Self.errorName(Int(error)))
        }
    }

    static func errorName(_ value: Int) -> String {
        switch value {
        case 6: return "command"
        case 7: return "transfer ID"
        case 8: return "sequence"
        case 9: return "offset"
        case 14: return "VDD charge timeout"
        case 15: return "VDD droop"
        case 16: return "EPD BUSY timeout"
        case 17: return "EPD I/O"
        case 18: return "STM32-ST25 I2C/Mailbox I/O"
        case 19: return "EXECUTE ACK timeout"
        case 20: return "hardware gate"
        default: return "protocol"
        }
    }
}

enum NCClientError: LocalizedError {
    case invalidImageLength(Int)
    case invalidAck(String)
    case mailboxBusy
    case mailboxResponse(String)
    case firmware(Int, String)
    case unsupportedTag
    case sessionDeadline
    case updateIncomplete(Int, Int)
    case silentPowerLost

    var errorDescription: String? {
        switch self {
        case .invalidImageLength(let count):
            return "画像は正確に4,736 bytes必要です（現在\(count) bytes）"
        case .invalidAck(let reason): return "ACK不正: \(reason)"
        case .mailboxBusy: return "Mailbox busy timeout"
        case .mailboxResponse(let reason): return "Mailbox応答不正: \(reason)"
        case .firmware(let code, let name): return "FW error=\(code) (\(name))"
        case .unsupportedTag: return "ISO 15693タグではありません"
        case .sessionDeadline: return "Core NFCの安全時間上限に到達しました"
        case .updateIncomplete(let state, let error):
            return "更新後state=\(state), error=\(error)"
        case .silentPowerLost: return "10秒無通信中にMCUが再起動しました"
        }
    }
}

extension Data {
    mutating func putUInt16LE(_ value: UInt16, at index: Int) {
        self[index] = UInt8(truncatingIfNeeded: value)
        self[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    mutating func putUInt32LE(_ value: UInt32, at index: Int) {
        self[index] = UInt8(truncatingIfNeeded: value)
        self[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[index + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    func uint16LE(at index: Int) -> UInt16 {
        UInt16(self[index]) | (UInt16(self[index + 1]) << 8)
    }
}
