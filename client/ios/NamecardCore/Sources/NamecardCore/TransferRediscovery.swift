import Foundation

/// Limited to image reception before COMMIT/EXECUTE. Restarting polling can
/// interrupt RF power; the coordinator must reconcile RAM loss on the next scan.
public struct TransferRediscovery: Sendable {
    public static let maximumAttempts = 6
    public private(set) var attempts = 0
    public private(set) var uid: Data?

    public init() {}

    public mutating func reserve(snapshot: TransferSnapshot?, now: TimeInterval,
                                 deadline: TimeInterval) -> Bool {
        guard attempts < Self.maximumAttempts, now + 8 < deadline,
              let snapshot, let tagUID = snapshot.uid,
              case .image = snapshot.job,
              !snapshot.executeSent, !snapshot.refreshMayBeActive,
              let request = snapshot.unconfirmedCommand,
              request.type == NCCommand.start.rawValue || request.type == NCCommand.data.rawValue,
              uid == nil || uid == tagUID else { return false }
        uid = tagUID
        attempts += 1
        return true
    }
}
