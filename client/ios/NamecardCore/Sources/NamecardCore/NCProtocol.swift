import Foundation

public enum NCCommand: UInt8, Sendable {
    case start = 1, data = 2, commit = 3, status = 4, execute = 5, pattern = 6, ndefWritePrepare = 7
}

public enum NCProtocolError: Error, LocalizedError {
    case frame(String)
    case firmware(code: UInt8)
    public var errorDescription: String? {
        switch self {
        case .frame(let reason): return "通信応答を確認できません：\(reason)"
        case .firmware(let code):
            let names: [UInt8: String] = [6: "このコマンドは利用できません", 7: "転送IDが一致しません", 8: "転送順序が一致しません", 9: "転送位置が一致しません", 14: "充電待機が時間切れになりました", 15: "電源電圧が低下しました", 16: "画面更新が時間切れになりました", 17: "電子ペーパーとの通信に失敗しました", 18: "本体のMailbox通信に失敗しました", 19: "更新開始の応答が確認されませんでした", 20: "ハードウェアの使用条件を満たしていません", 21: "本体の画像保存に失敗しました"]
            return "FWエラー \(code)：\(names[code] ?? "プロトコルエラー")"
        }
    }
}

public enum NCCRC {
    public static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc &<< 1) ^ 0x1021 : crc &<< 1 }
        }
        return crc
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        }
        return crc ^ 0xffffffff
    }
}

public struct NCFrame: Sendable, Equatable {
    public let type: UInt8
    public let transferID: UInt16
    public let sequence: UInt16
    public let offset: UInt16
    public let payload: Data

    public init(command: NCCommand, transferID: UInt16, sequence: UInt16 = 0, offset: UInt16 = 0, payload: Data = Data()) {
        self.type = command.rawValue
        self.transferID = transferID
        self.sequence = sequence
        self.offset = offset
        self.payload = payload
    }

    public func encoded() throws -> Data {
        guard payload.count <= 240 else { throw NCProtocolError.frame("Mailboxは最大256 bytesです") }
        var raw = Data([0x4e, 0x43, 1, type])
        raw.appendLE(transferID)
        raw.appendLE(sequence)
        raw.appendLE(offset)
        raw.appendLE(UInt16(payload.count))
        raw.appendLE(UInt16(0))
        raw.appendLE(NCCRC.crc16(payload))
        let crc = NCCRC.crc16(raw.prefix(12) + raw.suffix(2))
        raw[12] = UInt8(truncatingIfNeeded: crc)
        raw[13] = UInt8(truncatingIfNeeded: crc >> 8)
        raw.append(payload)
        return raw
    }
}

public struct NCAck: Sendable {
    public let responseType: UInt8
    public let transferID: UInt16
    public let requestSequence: UInt16
    public let acknowledgedType: UInt8
    public let code: UInt8
    public let state: UInt8
    public let error: UInt8
    public let expectedSequence: UInt16
    public let expectedOffset: UInt16
    public let vddMV: UInt16
    public let minimumVddMV: UInt16
    public let quietMS: UInt16
    public let ehControl: UInt8
    public let capabilities: UInt8

    public var hasPendingImage: Bool { capabilities & 0x04 != 0 }
    public var supportsBatchClean: Bool { capabilities & 0x08 != 0 }
    public var batchCleanActive: Bool { capabilities & 0x10 != 0 }
    public var supportsGray4: Bool { capabilities & 0x20 != 0 }
    public var currentDisplayIsGray: Bool { capabilities & 0x40 != 0 }
    public var hasGrayPlane0Pending: Bool { capabilities & 0x80 != 0 }

    public init(data: Data, request: NCFrame) throws {
        // Rebase slices: callers can pass Data whose startIndex is not zero.
        let raw = Data([UInt8](data))
        guard raw.count == 32 else { throw NCProtocolError.frame("ACKの長さが不正です") }
        guard raw[0] == 0x4e, raw[1] == 0x43, raw[2] == 1 else {
            throw NCProtocolError.frame("NC v1ではありません")
        }
        guard raw[3] == 0x80 || raw[3] == 0x81, raw.u16(10) == 16 else {
            throw NCProtocolError.frame("ACKの種類またはペイロード長が不正です")
        }
        guard NCCRC.crc16(raw.prefix(12) + raw[14..<16]) == raw.u16(12),
              NCCRC.crc16(raw[16..<32]) == raw.u16(14) else {
            throw NCProtocolError.frame("CRCが一致しません")
        }
        guard raw.u16(4) == request.transferID, raw.u16(6) == request.sequence,
              raw[16] == request.type else { throw NCProtocolError.frame("別のコマンドへの応答です") }
        guard raw.u16(8) == raw.u16(22) else { throw NCProtocolError.frame("ACKの転送位置が矛盾しています") }
        guard [0, 1, 2, 3, 4, 0x80].contains(raw[17]), raw[18] <= 7 else {
            throw NCProtocolError.frame("ACKの状態が不正です")
        }
        guard (raw[3] == 0x81) == (raw[17] == 0x80) else {
            throw NCProtocolError.frame("ACKとエラー種別が矛盾しています")
        }
        responseType = raw[3]
        transferID = raw.u16(4)
        requestSequence = raw.u16(6)
        acknowledgedType = raw[16]
        code = raw[17]
        state = raw[18]
        error = raw[19]
        expectedSequence = raw.u16(20)
        expectedOffset = raw.u16(22)
        vddMV = raw.u16(24)
        minimumVddMV = raw.u16(26)
        quietMS = raw.u16(28)
        ehControl = raw[30]
        capabilities = raw[31]
        guard expectedOffset <= 4_736 else { throw NCProtocolError.frame("転送位置が画像サイズを超えています") }
        // Rejections and STATUS report the remote state for recovery. For successful
        // mutations, require the exact state advancement from firmware nc_protocol.c.
        if code != 0x80 && error == 0 {
            switch NCCommand(rawValue: request.type) {
            case .start: try requireProgress(sequence: 1, offset: 0)
            case .pattern: try requireProgress(sequence: 1, offset: 4_736)
            case .data:
                try requireProgress(sequence: Int(request.sequence) + 1, offset: Int(request.offset) + request.payload.count)
            case .commit: try requireProgress(sequence: Int(request.sequence) + 1, offset: Int(request.offset))
            case .execute:
                // Firmware can defer EXECUTE while charging without consuming it.
                let delta = code == 3 && state == 2 ? 0 : 1
                try requireProgress(sequence: Int(request.sequence) + delta, offset: Int(request.offset))
            case .status, .ndefWritePrepare, .none: break
            }
        }
    }

    public func requireSuccess() throws {
        guard code != 0x80 && error == 0 else { throw NCProtocolError.firmware(code: error) }
    }

    private func requireProgress(sequence: Int, offset: Int) throws {
        guard Int(expectedSequence) == sequence, Int(expectedOffset) == offset else {
            throw NCProtocolError.frame("転送順序または位置が一致しません")
        }
    }
}

public enum NCMetadata {
    /// Monochrome only: gray-plane EXECUTE cannot fit the iOS session deadline.
    public static func image(_ image: Data, batchClean: Bool) throws -> Data {
        guard image.count == ImageFormat.dotDensity.byteCount else { throw NativeImageError.invalidByteCount }
        var result = Data()
        result.appendLE(UInt16(NativeImage.width))
        result.appendLE(UInt16(NativeImage.height))
        result.appendLE(UInt16(image.count))
        result.append(contentsOf: [1, 1])
        result.appendLE(NCCRC.crc32(image))
        result.appendLE(UInt32(batchClean ? 1 : 0))
        return result
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        for shift in stride(from: 0, to: T.bitWidth, by: 8) { append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    func u16(_ index: Int) -> UInt16 { UInt16(self[index]) | UInt16(self[index + 1]) << 8 }
}
