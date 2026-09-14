import CoreNFC
import Foundation
import NamecardCore

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One instance per connected tag. All operations are serialized by its owner.
final class ST25Mailbox: MailboxTransport, URLTagTransport, @unchecked Sendable {
    let tag: NFCISO15693Tag
    let onExchange: @Sendable (NCAck, TimeInterval) -> Void
    private let onEvent: @Sendable (String) -> Void
    private let deadline: TimeInterval
    private var initialized = false
    private var lastControl: UInt8?
    var identifier: Data { tag.identifier }

    init(tag: NFCISO15693Tag, deadline: TimeInterval,
         onEvent: @escaping @Sendable (String) -> Void = { _ in },
         onExchange: @escaping @Sendable (NCAck, TimeInterval) -> Void) {
        self.tag = tag
        self.deadline = deadline
        self.onExchange = onExchange
        self.onEvent = onEvent
    }

    func checkConnection() throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw AppFailure("接続が終了しました。同じ名刺をもう一度スキャンしてください。")
        }
        guard tag.isAvailable else {
            throw MailboxTransportError.connectionLost("タグへの接続が失われました（isAvailable=false）。")
        }
    }

    func command(_ code: Int, _ parameters: Data) async throws -> Data {
        try checkConnection()
        do {
            // Core NFC inserts manufacturer information; no Android RF header or UID here.
            return try await CancellableNFCRequest.run { [self] in
                try await tag.customCommand(requestFlags: [.highDataRate],
                                            customCommandCode: code,
                                            customRequestParameters: parameters)
            }
        } catch {
            throw Self.transportError(error, command: code)
        }
    }

    static func transportError(_ error: Error, command: Int? = nil) -> Error {
        if error is CancellationError { return error }
        let nsError = error as NSError
        let isoCode = (nsError.userInfo[NFCISO15693TagResponseErrorKey] as? NSNumber)?.intValue
        let isoDetail = isoCode.map { String(format: " ISO15693=%02X", $0) } ?? ""
        let detail = (command.map { String(format: "ST25 %02X", $0) } ?? "NFC接続") +
            " \(nsError.domain)(\(nsError.code))\(isoDetail): \(error.localizedDescription)"
        if nsError.domain == NFCErrorDomain,
           nsError.code == NFCReaderError.Code.readerTransceiveErrorTagConnectionLost.rawValue ||
            nsError.code == NFCReaderError.Code.readerTransceiveErrorTagNotConnected.rawValue {
            return MailboxTransportError.connectionLost(detail)
        }
        if isoCode == 0x10, command == 0xad || command == 0xae {
            return MailboxAvailabilityError.unavailable(detail)
        }
        if nsError.domain == NFCErrorDomain,
           nsError.code == NFCReaderError.Code.readerTransceiveErrorRetryExceeded.rawValue ||
            (nsError.code == NFCReaderError.Code.readerTransceiveErrorTagResponseError.rawValue &&
             (isoCode == nil || isoCode == 0x0f)) {
            return MailboxTransportError.transient(detail)
        }
        return AppFailure(detail)
    }

    func control() async throws -> UInt8 {
        let value = try await MailboxControlReader.read(deadline: deadline, onRetry: { [self] attempt in
            onEvent("ST25 AD MB_CTRL読取を再試行 \(attempt)/3")
        }) { [self] in
            let result = try await command(0xad, Data([0x0d]))
            guard result.count == 1 else { throw AppFailure("Mailboxレジスタの応答長が不正です。") }
            return result[0]
        }
        lastControl = value
        return value
    }

    func setEnabled(_ enabled: Bool) async throws {
        let desired: UInt8 = enabled ? 1 : 0
        if try await control() & 1 != desired {
            _ = try await command(0xae, Data([0x0d, desired]))
        }
        guard try await control() & 1 == desired else {
            throw AppFailure(enabled ? "Mailboxを再開できません。再スキャンしてください。" : "Mailboxを停止できません。")
        }
    }

    func prepareForURL() async throws {
        try await URLMailboxStartup.enable(deadline: deadline, readEnergy: { [self] in
            let bytes = try await command(0xad, Data([0x02]))
            guard bytes.count == 1 else { throw AppFailure("電源レジスタの応答長が不正です。") }
            return bytes[0]
        }, readControl: { [self] in try await control() }, enableMailbox: { [self] in
            _ = try await command(0xae, Data([0x0d, 1]))
        }, onWait: onEvent)
        initialized = true
    }

    private func readACK() async throws -> Data {
        let data = try await command(0xac, Data([0, 31]))
        guard data.count == 32 else { throw NCProtocolError.frame("ACK長が不正です（\(data.count) / 32 bytes）。") }
        return data
    }

    func exchange(_ frame: NCFrame, timeout: TimeInterval) async throws -> NCAck {
        if !initialized {
            try await setEnabled(true)
            initialized = true
        }
        let started = ProcessInfo.processInfo.systemUptime
        let context = "NC=\(frame.type) id=\(frame.transferID) seq=\(frame.sequence) offset=\(frame.offset) length=\(frame.payload.count)"
        onEvent("TX \(context)")
        let freeUntil = min(deadline, started + 1)
        while true {
            let value = try await control()
            if value & 0x06 == 0 { break }
            if value & 0x02 != 0 {
                let bytes = try await readACK()
                if frame.type == NCCommand.data.rawValue, let ack = try? NCAck(data: bytes, request: frame) {
                    onEvent("遅れて届いたDATA ACKを確認: \(context)")
                    onExchange(ack, ProcessInfo.processInfo.systemUptime - started)
                    return ack
                }
                onEvent("以前のACKを読み取り、Mailboxの空きを待ちます: \(context)")
            }
            guard ProcessInfo.processInfo.systemUptime < freeUntil else {
                throw MailboxTransportError.transient("Mailboxが使用中です。\(context) MB_CTRL=\(String(format: "%02X", value))")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let bytes = try frame.encoded()
        guard !bytes.isEmpty, bytes.count <= 256 else { throw AppFailure("Mailboxの転送長を超えています。") }
        _ = try await command(0xaa, Data([UInt8(bytes.count - 1)]) + bytes)
        try await Task.sleep(for: .milliseconds(50))
        let ackUntil = min(deadline, ProcessInfo.processInfo.systemUptime + timeout)
        while ProcessInfo.processInfo.systemUptime < ackUntil {
            if try await control() & 0x02 != 0 {
                let raw = try await readACK()
                let ack: NCAck
                do { ack = try NCAck(data: raw, request: frame) }
                catch {
                    onEvent("ACK検証失敗: \(context) raw=\(raw.map { String(format: "%02X", $0) }.joined()) \(error.localizedDescription)")
                    throw error
                }
                onExchange(ack, ProcessInfo.processInfo.systemUptime - started)
                return ack
            }
            // The MCU polls at 25 ms. Avoid repeated RF polls while its I2C
            // transaction is active; Core NFC can report those collisions as
            // tag-response/connection errors (ST's AN4910 support guidance).
            try await Task.sleep(for: .milliseconds(50))
        }
        let controlText = lastControl.map { String(format: "%02X", $0) } ?? "--"
        throw MailboxTransportError.transient("名刺の応答がありません（MCU ACK timeout）。\(context) MB_CTRL=\(controlText)。同じ名刺で再開してください。")
    }

    func readMemory() async throws -> Data {
        var memory = Data()
        for block in 0..<128 {
            memory.append(try await readBlock(block))
        }
        return memory
    }

    func readNDEFMessage() async throws -> Data? {
        try await URLNDEFReader.read { [self] in try await readBlock($0) }
    }

    private func readBlock(_ block: Int) async throws -> Data {
        let bytes = try await readNFC("URLメモリ block=\(block)") { [self] in
            try await tag.readSingleBlock(requestFlags: [.highDataRate], blockNumber: UInt8(block))
        }
        guard bytes.count == 4 else { throw AppFailure("この名刺のメモリ構成には対応していません。") }
        return bytes
    }

    private func request<Value>(_ context: String,
                                operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        do {
            try checkConnection()
            return try await CancellableNFCRequest.run(operation)
        } catch {
            onEvent("\(context): \(error.localizedDescription)")
            // Keep typed errors from checkConnection for the rediscovery policy.
            if error is MailboxTransportError { throw error }
            throw Self.transportError(error)
        }
    }

    private func readNFC<Value>(_ context: String,
                                operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await NFCReadRetry.read(deadline: deadline, onRetry: { [self] attempt in
            onEvent("\(context) 読取を再試行 \(attempt)/3")
        }) { [self] in try await request(context, operation: operation) }
    }

    func blankIdentity() async throws -> Type5Identity {
        let info = try await readNFC("URLタグ情報") { [self] in
            let result = try await tag.systemInfo(requestFlags: [.highDataRate])
            return (blockSize: result.blockSize, totalBlocks: result.totalBlocks, icReference: result.icReference)
        }
        guard tag.icManufacturerCode == 2, info.blockSize == 4, info.totalBlocks == 128, info.icReference == 0x24 else {
            throw AppFailure("未フォーマットのこのタグには対応していません。")
        }
        var writable = true
        for start in stride(from: 0, to: 128, by: 16) {
            let statuses = try await readNFC("URL保護状態 block=\(start)") { [self] in
                try await tag.getMultipleBlockSecurityStatus(
                    requestFlags: [.highDataRate], blockRange: NSRange(location: start, length: 16))
            }
            guard statuses.count == 16 else { throw AppFailure("メモリの保護状態を確認できません。") }
            writable = writable && statuses.allSatisfy { $0.intValue & 1 == 0 }
        }
        return Type5Identity(manufacturerCode: 2, icReference: 0x24,
                             blockCount: 128, blockSize: 4, allBlocksWritable: writable)
    }

    func ndefStatus() async throws -> URLMemoryStatus {
        let (status, capacity) = try await readNFC("URL NDEF状態") { [self] in try await tag.queryNDEFStatus() }
        switch status {
        case .readWrite: return .readWrite(capacity)
        case .readOnly: return .readOnly
        case .notSupported: return .notSupported
        @unknown default: throw AppFailure("この名刺のNDEF形式には対応していません。")
        }
    }

    func writeMessage(_ bytes: Data) async throws {
        guard let message = NFCNDEFMessage(data: bytes) else { throw AppFailure("URLデータを作成できません。") }
        // A failed write may have reached EEPROM. Never retry it on this tag
        // object; retain the journal and reconnect before attempting recovery.
        try await request("URL NDEF書込") { [self] in try await tag.writeNDEF(message) }
    }

    func writeBlock(_ write: Type5BlockWrite) async throws {
        try await request("URL初期化 block=\(write.block)") { [self] in
            try await tag.writeSingleBlock(requestFlags: [.highDataRate], blockNumber: UInt8(write.block), dataBlock: write.bytes)
        }
    }
}
