import Foundation
import NamecardCore

enum MailboxAvailabilityError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        if case .unavailable(let detail) = self {
            return "Mailboxを利用できません。名刺の電源状態と初期設定を確認してください（VCC／MB_MODE）。\n\(detail)"
        }
        return nil
    }
}

enum URLMailboxStartup {
    /// Matches Android's VCC check and bounded, mostly RF-quiet startup window.
    static func enable(deadline: TimeInterval, clock: any TransferClock = SystemTransferClock(),
                       readEnergy: @Sendable () async throws -> UInt8,
                       readControl: @Sendable () async throws -> UInt8,
                       enableMailbox: @Sendable () async throws -> Void,
                       onWait: @Sendable (String) -> Void = { _ in }) async throws {
        let until = min(deadline, await clock.now() + 8)
        var lastError: Error?
        while await clock.now() < until {
            try Task.checkCancellation()
            do {
                let energy = try await readEnergy()
                if energy & 0x08 != 0 {
                    if try await readControl() & 1 != 0 { return }
                    try await enableMailbox()
                    guard await clock.now() + 0.025 < until else { break }
                    try await clock.sleep(seconds: 0.025)
                    if try await readControl() & 1 != 0 { return }
                }
                onWait(String(format: "URL準備: 電源／Mailboxの起動待ち EH_CTRL=%02X", energy))
            } catch {
                switch error {
                case is MailboxAvailabilityError, MailboxTransportError.transient:
                    lastError = error
                    onWait("URL準備: \(error.localizedDescription)")
                default: throw error
                }
            }
            let remaining = until - (await clock.now())
            guard remaining > 0 else { break }
            try await clock.sleep(seconds: min(1, remaining))
        }
        try Task.checkCancellation()
        if let lastError { throw lastError }
        throw AppFailure("名刺の電源／Mailboxの起動を確認できませんでした。同じ名刺を再スキャンしてください。")
    }
}
