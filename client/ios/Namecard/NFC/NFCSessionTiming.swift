import Foundation

/// This is app-side backoff, not a guarantee that Core NFC has released its RF
/// resource. Only user scans start another session; no automatic begin() loop.
struct NFCSessionTiming {
    private var busyFailures = 0

    mutating func ended(systemBusy: Bool) -> TimeInterval {
        busyFailures = systemBusy ? min(busyFailures + 1, 3) : 0
        return systemBusy ? min(Double(busyFailures * 2), 6) : 1
    }

    mutating func becameActive() { busyFailures = 0 }
}

/// Avoid repeatedly rebuilding the system NFC sheet for every DATA ACK.
struct NFCAlertRateLimit {
    private var lastText: String?
    private var lastTime: TimeInterval = -.infinity

    mutating func shouldSend(_ text: String, now: TimeInterval, force: Bool = false) -> Bool {
        guard text != lastText, force || now - lastTime >= 1 else { return false }
        lastText = text; lastTime = now
        return true
    }
}
