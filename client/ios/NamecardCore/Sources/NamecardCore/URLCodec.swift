import Foundation

/// A clear operation is explicit; blank URL input still fails validation.
public enum URLUpdate: Sendable, Equatable {
    case set(String)
    case clear

    public var isClear: Bool { self == .clear }

    public func normalized() throws -> URLUpdate {
        switch self {
        case .set(let input): return .set(try URLCodec.normalize(input))
        case .clear: return .clear
        }
    }

    public func ndefMessage() throws -> Data {
        switch self {
        case .set(let input): return try URLCodec.ndefMessage(for: input)
        case .clear: return URLCodec.emptyNDEFMessage
        }
    }
}

public enum URLCodecError: Error, LocalizedError {
    case empty, whitespace, scheme, host, invalidURL, tooLong, malformedType5, unsafeFormatting
    public var errorDescription: String? {
        switch self {
        case .empty: return "URLを入力してください"
        case .whitespace: return "空白を含まないURLを入力してください"
        case .scheme: return "http:// または https:// のURLを入力してください"
        case .host: return "ホスト名を含むURLを入力してください"
        case .invalidURL: return "URLの形式を確認してください"
        case .tooLong: return "URLのNDEFメッセージは480 bytes以内にしてください"
        case .malformedType5: return "NDEFの読出しデータが不完全です"
        case .unsafeFormatting: return "初期状態のST25DV04Kと確認できないため初期化できません"
        }
    }
}

public struct Type5Identity: Sendable {
    public let manufacturerCode: UInt8
    public let icReference: UInt8
    public let blockCount: Int
    public let blockSize: Int
    public let allBlocksWritable: Bool

    public init(manufacturerCode: UInt8, icReference: UInt8, blockCount: Int, blockSize: Int, allBlocksWritable: Bool) {
        self.manufacturerCode = manufacturerCode
        self.icReference = icReference
        self.blockCount = blockCount
        self.blockSize = blockSize
        self.allBlocksWritable = allBlocksWritable
    }
}

public struct Type5BlockWrite: Codable, Sendable, Equatable {
    public let block: Int
    public let bytes: Data
    public init(block: Int, bytes: Data) { self.block = block; self.bytes = bytes }
}

public enum URLCodec {
    public static let maxNDEFBytes = 480
    /// MB | ME | SR, TNF_EMPTY, zero type and payload lengths. No URI remains
    /// in the active NDEF message; the tag stays readable and writable.
    public static let emptyNDEFMessage = Data([0xd0, 0, 0])

    /// Matches Android UrlSetting: preserve existing escapes, ASCII-encode Unicode
    /// paths, allow bare hosts with ports, and reject non-HTTP schemes.
    public static func normalize(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw URLCodecError.empty }
        guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw URLCodecError.whitespace
        }
        let webScheme = value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression)
        if webScheme == nil, let colon = value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) {
            let suffix = value[colon.upperBound...].split(separator: "/", omittingEmptySubsequences: false).first ?? ""
            guard Int32(suffix) != nil else { throw URLCodecError.scheme }
        }
        let candidate = webScheme == nil ? "https://" + value : value
        guard let colon = candidate.firstIndex(of: ":"), ["http", "https"].contains(candidate[..<colon].lowercased()) else {
            throw URLCodecError.scheme
        }
        // URLComponents repairs malformed escapes; reject them before parsing.
        let raw = Array(candidate.utf8)
        for i in raw.indices where raw[i] == 0x25 {
            guard i + 2 < raw.count, isHex(raw[i + 1]), isHex(raw[i + 2]) else { throw URLCodecError.invalidURL }
        }
        let forbidden = CharacterSet(charactersIn: "\"<>\\^`{|}")
        guard !candidate.unicodeScalars.contains(where: forbidden.contains) else { throw URLCodecError.invalidURL }
        let afterScheme = candidate[candidate.index(colon, offsetBy: 3)...]
        let authority = afterScheme.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
        let tail = afterScheme.dropFirst(authority.count)
        let path = tail.first == "/" ? tail.prefix(while: { $0 != "?" && $0 != "#" }) : ""
        if path.contains(where: { $0 == "[" || $0 == "]" }) {
            throw URLCodecError.invalidURL
        }
        guard let components = URLComponents(string: candidate), let host = components.host, !host.isEmpty else {
            throw URLCodecError.host
        }
        // java.net.URI.host does not silently turn Unicode names into IDNs.
        guard validHost(host) else { throw URLCodecError.host }
        let hostAndPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
        if let portColon = hostAndPort.lastIndex(of: ":"),
           !hostAndPort[portColon...].contains("]") {
            let port = hostAndPort[hostAndPort.index(after: portColon)...]
            guard port.isEmpty || (port.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) && Int32(port) != nil) else {
                throw URLCodecError.host
            }
        }
        var ascii = ""
        for scalar in candidate.unicodeScalars {
            if scalar.isASCII { ascii.unicodeScalars.append(scalar) }
            else { for byte in String(scalar).utf8 { ascii += String(format: "%%%02X", byte) } }
        }
        return ascii
    }

    /// A single well-known URI record, byte-identical to Android NdefRecord.createUri.
    public static func ndefMessage(for input: String) throws -> Data {
        var uri = try normalize(input)
        if let colon = uri.firstIndex(of: ":") { uri = uri[..<colon].lowercased() + uri[colon...] }
        let prefixes: [(String, UInt8)] = [("http://www.", 1), ("https://www.", 2), ("http://", 3), ("https://", 4)]
        guard let prefix = prefixes.first(where: { uri.hasPrefix($0.0) }) else { throw URLCodecError.scheme }
        let payload = Data([prefix.1]) + Data(uri.dropFirst(prefix.0.count).utf8)
        var result: Data
        if payload.count <= 255 {
            result = Data([0xd1, 1, UInt8(payload.count), 0x55])
        } else {
            let length = UInt32(payload.count)
            result = Data([0xc1, 1, UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16), UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length), 0x55])
        }
        result.append(payload)
        guard result.count <= maxNDEFBytes else { throw URLCodecError.tooLong }
        return result
    }

    /// Extract the first NDEF TLV from a full or sufficiently long partial dump.
    /// nil means no CC/NDEF; a truncated TLV is an error, never a successful readback.
    public static func type5NDEF(in memory: Data) throws -> Data? {
        let bytes = [UInt8](memory)
        guard bytes.count >= 4 else { throw URLCodecError.malformedType5 }
        guard bytes[0] == 0xe1 || bytes[0] == 0xe2 else { return nil }
        var offset = bytes[2] == 0 ? 8 : 4
        guard offset <= bytes.count else { throw URLCodecError.malformedType5 }
        while offset < bytes.count {
            let type = bytes[offset]; offset += 1
            if type == 0 { continue }
            if type == 0xfe { return nil }
            guard offset < bytes.count else { throw URLCodecError.malformedType5 }
            var length = Int(bytes[offset]); offset += 1
            if length == 255 {
                guard offset + 2 <= bytes.count else { throw URLCodecError.malformedType5 }
                length = Int(bytes[offset]) * 256 + Int(bytes[offset + 1]); offset += 2
            }
            guard offset + length <= bytes.count else { throw URLCodecError.malformedType5 }
            if type == 3 { return Data(bytes[offset..<(offset + length)]) }
            offset += length
        }
        return nil
    }

    /// No password, lock bit, MB_MODE, or EH_MODE writes. The caller must persist
    /// this exact ordered plan with the UID before applying it, then verify raw
    /// NDEF bytes and restore Mailbox before reporting success.
    /// ST DS10925 Rev11: factory user memory is zero; IC_REF=24h identifies 04K.
    public static func blankType5WritePlan(memory: Data, message: Data, identity: Type5Identity) throws -> [Type5BlockWrite] {
        guard identity.manufacturerCode == 2, identity.icReference == 0x24,
              identity.blockCount == 128, identity.blockSize == 4, identity.allBlocksWritable,
              memory.count == 512, memory.allSatisfy({ $0 == 0 }) else { throw URLCodecError.unsafeFormatting }
        guard !message.isEmpty, message.count <= maxNDEFBytes else { throw URLCodecError.tooLong }
        var target = Data([0xe1, 0x40, 0x40, 0])
        if message.count < 255 { target.append(contentsOf: [3, UInt8(message.count)]) }
        else { target.append(contentsOf: [3, 255, UInt8(message.count >> 8), UInt8(message.count & 255)]) }
        target.append(message)
        target.append(0xfe)
        while target.count % 4 != 0 { target.append(0) }
        var writes = [Type5BlockWrite(block: 0, bytes: target[0..<4]), Type5BlockWrite(block: 1, bytes: Data([3, 0, 0xfe, 0]))]
        for block in 2..<(target.count / 4) { writes.append(Type5BlockWrite(block: block, bytes: target[(block * 4)..<(block * 4 + 4)])) }
        // The length is entirely in block 1 for both short and extended TLVs.
        writes.append(Type5BlockWrite(block: 1, bytes: target[4..<8]))
        return writes
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)
    }

    private static func validHost(_ host: String) -> Bool {
        guard host.unicodeScalars.allSatisfy({ $0.isASCII }), !host.contains("%"), !host.contains("@") else { return false }
        if host.contains(":") { return true } // IPv6 syntax has already been checked by URLComponents.
        var labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.last?.isEmpty == true { labels.removeLast() }
        guard !labels.isEmpty, labels.allSatisfy({ label in
            !label.isEmpty && label.first != "-" && label.last != "-" && label.utf8.allSatisfy {
                ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45
            }
        }) else { return false }
        if labels.count > 1, let first = labels.last?.utf8.first, first >= 48 && first <= 57 {
            return labels.count == 4 && labels.allSatisfy { label in
                label.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } && Int(label).map { $0 <= 255 } == true
            }
        }
        return true
    }
}
