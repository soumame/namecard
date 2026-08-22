import CoreNFC
import Foundation

final class ST25Mailbox {
    private let tag: NFCISO15693Tag
    private static let ackSettleNanoseconds: UInt64 = 80_000_000
    private static let ackPollNanoseconds: UInt64 = 25_000_000

    init(tag: NFCISO15693Tag) {
        self.tag = tag
    }

    func enable() async throws {
        let control = try await readControl()
        if (control & 0x01) != 0 { return }
        _ = try await command(0xAE, parameters: Data([0x0D, 0x01]))
        guard (try await readControl() & 0x01) != 0 else {
            throw NCClientError.mailboxResponse("MB_ENを書き込めませんでした。MB_MODE=1を確認してください")
        }
    }

    func exchange(_ message: Data) async throws -> NCAck {
        try await waitUntilFree(timeout: 1.0)
        guard !message.isEmpty, message.count <= 256 else {
            throw NCClientError.mailboxResponse("request length \(message.count)")
        }
        var request = Data([UInt8(message.count - 1)])
        request.append(message)
        _ = try await command(0xAA, parameters: request)

        // FW polls its I2C mailbox every 25 ms. Waiting before the first RF
        // register read avoids colliding with the MCU ACK publication.
        try await Task.sleep(nanoseconds: Self.ackSettleNanoseconds)
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if (try await readControl() & 0x02) != 0 {
                let response = try await readHostMessage()
                return try NCAck(response)
            }
            try await Task.sleep(nanoseconds: Self.ackPollNanoseconds)
        }

        let mailbox = try? await readControl()
        let energy = try? await readDynamic(address: 0x02)
        let detail = String(format: "MB_CTRL=%02X EH_CTRL=%02X", mailbox ?? 0xFF,
                            energy ?? 0xFF)
        throw NCClientError.mailboxResponse("MCU ACK timeout; \(detail)")
    }

    func readDynamic(address: UInt8) async throws -> UInt8 {
        let response = try await command(0xAD, parameters: Data([address]))
        guard let value = response.first else {
            throw NCClientError.mailboxResponse("dynamic register \(address) is empty")
        }
        return value
    }

    private func readControl() async throws -> UInt8 {
        try await readDynamic(address: 0x0D)
    }

    private func waitUntilFree(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let control = try await readControl()
            if (control & 0x06) == 0 { return }
            if (control & 0x02) != 0 {
                _ = try await readHostMessage() // discard a complete stale ACK
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NCClientError.mailboxBusy
    }

    private func readHostMessage() async throws -> Data {
        let response = try await command(
            0xAC, parameters: Data([0x00, UInt8(NCProtocol.ackFrameSize - 1)]))
        guard response.count == NCProtocol.ackFrameSize else {
            throw NCClientError.mailboxResponse("ACK length \(response.count)")
        }
        return response
    }

    private func command(_ code: Int, parameters: Data) async throws -> Data {
        // Core NFC inserts ST's manufacturer code automatically. ST specifies
        // non-addressed mode for iOS custom commands, so only highDataRate is
        // supplied here; do not prepend manufacturer code or UID.
        try await withCheckedThrowingContinuation { continuation in
            tag.customCommand(requestFlags: [.highDataRate],
                              customCommandCode: code,
                              customRequestParameters: parameters) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }
}
