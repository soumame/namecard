import Foundation
import NamecardCore

/// MB_CTRL reads have no consuming/write side effects. Never use this loop for
/// mailbox data reads, COMMIT, EXECUTE, or EEPROM writes.
enum MailboxControlReader {
    static func read(deadline: TimeInterval, clock: any TransferClock = SystemTransferClock(),
                     onRetry: @Sendable (Int) -> Void = { _ in },
                     operation: @Sendable () async throws -> UInt8) async throws -> UInt8 {
        try await NFCReadRetry.read(deadline: deadline, clock: clock, onRetry: onRetry, operation: operation)
    }
}

/// Only for reads without side effects. Never replay ACK reads or EEPROM writes.
enum NFCReadRetry {
    static func read<Value>(deadline: TimeInterval, clock: any TransferClock = SystemTransferClock(),
                            onRetry: @Sendable (Int) -> Void = { _ in },
                            operation: @Sendable () async throws -> Value) async throws -> Value {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                try Task.checkCancellation()
                guard case MailboxTransportError.transient = error, attempt < 3 else { throw error }
                let delay = 0.1 * Double(attempt)
                guard await clock.now() + delay + 0.25 < deadline else { throw error }
                attempt += 1
                onRetry(attempt)
                try await clock.sleep(seconds: delay)
            }
        }
    }
}
