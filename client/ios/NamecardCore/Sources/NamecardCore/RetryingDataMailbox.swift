import Foundation

/// The adapter marks only recoverable RF responses/timeouts as transient.
/// Lost connections, invalid sessions and configuration errors are not retried.
public enum MailboxTransportError: Error, LocalizedError, Sendable {
    case transient(String)
    case connectionLost(String)

    public var errorDescription: String? {
        switch self { case .transient(let detail), .connectionLost(let detail): return detail }
    }
}

/// Replays only the exact DATA frame. Firmware recognizes duplicate DATA by
/// transfer ID, sequence, offset, length and payload CRC (nc_protocol.c).
/// EXECUTE and COMMIT have quiet/persistence side effects and never enter this loop.
public struct RetryingDataMailbox: MailboxTransport {
    private let transport: any MailboxTransport
    private let clock: any TransferClock
    private let deadline: TimeInterval
    private let onRetry: @Sendable (NCFrame, Int, String) -> Void

    public init(transport: any MailboxTransport, deadline: TimeInterval,
                clock: any TransferClock = SystemTransferClock(),
                onRetry: @escaping @Sendable (NCFrame, Int, String) -> Void = { _, _, _ in }) {
        self.transport = transport
        self.deadline = deadline
        self.clock = clock
        self.onRetry = onRetry
    }

    public func exchange(_ frame: NCFrame, timeout: TimeInterval) async throws -> NCAck {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                return try await transport.exchange(frame, timeout: timeout)
            } catch {
                try Task.checkCancellation()
                guard frame.type == NCCommand.data.rawValue, attempt < 3, Self.canRetry(error) else {
                    throw error
                }
                // Include mailbox-free wait, ACK settling and response timeout.
                // A fresh scan is required if one bounded retry no longer fits.
                let pause = 0.25 * Double(attempt)
                guard await clock.now() + pause + 1.0 + 0.05 + timeout + 0.25 < deadline else {
                    throw error
                }
                attempt += 1
                onRetry(frame, attempt, error.localizedDescription)
                try await clock.sleep(seconds: pause)
            }
        }
    }

    private static func canRetry(_ error: Error) -> Bool {
        if case MailboxTransportError.transient = error { return true }
        // A consumed, damaged or stale ACK cannot advance progress. Replaying
        // DATA still requires a fresh ACK to pass all the original checks.
        if case NCProtocolError.frame = error { return true }
        return false
    }
}
