import Foundation

/// A fresh tag object is required after connection loss. EEPROM recovery stays
/// in URLWriter's UID-bound journal; this policy only bounds session polling.
struct URLRediscovery {
    static let maximumAttempts = 3
    private(set) var attempts = 0
    private(set) var uid: Data?

    func accepts(_ candidate: Data) -> Bool { uid == nil || uid == candidate }

    mutating func reserve(uid candidate: Data, now: TimeInterval, deadline: TimeInterval) -> Bool {
        guard accepts(candidate), attempts < Self.maximumAttempts, now + 14 < deadline else { return false }
        uid = candidate
        attempts += 1
        return true
    }
}
