import Foundation

/// The adapter validates the raw ACK against the request before returning it.
public protocol MailboxTransport: Sendable {
    func exchange(_ frame: NCFrame, timeout: TimeInterval) async throws -> NCAck
}

/// A monotonic clock. `deadline` passed to the coordinator uses this clock's epoch.
public protocol TransferClock: Sendable {
    func now() async -> TimeInterval
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemTransferClock: TransferClock {
    public init() {}
    public func now() async -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

public enum TransferError: Error, LocalizedError, Sendable, Equatable {
    case busy, noPendingJob, invalidImage, grayWriteUnavailable, invalidPattern
    case differentTag, unvalidatedHardware, unvalidatedRoute(String), invalidMeasurement
    case inconsistentAcknowledgement, recoveryLimit, chargingTimeout, firmwareRestarted

    public var errorDescription: String? {
        switch self {
        case .busy: return "NFC処理が実行中です。"
        case .noPendingJob: return "先に書き込み内容を選択してください。"
        case .invalidImage: return "BINのサイズが正しくありません。"
        case .grayWriteUnavailable: return "4階調のNFC書き込みは、現FWとiOSのセッション時間の制約により利用できません。"
        case .invalidPattern: return "パターンは1〜10から選択してください。"
        case .differentTag: return "再開するには、前回と同じ名刺をスキャンしてください。"
        case .unvalidatedHardware: return "販売済み基板でのiPhone実機検証が未完了のため、表示書き込みは公開版では無効です。"
        case .unvalidatedRoute(let route): return "この更新経路（\(route)）の実機検証が完了していません。"
        case .invalidMeasurement: return "検証記録と有効な更新時間上限が必要です。"
        case .inconsistentAcknowledgement: return "FW応答の転送位置が送信内容と一致しません。再スキャンしてください。"
        case .recoveryLimit: return "転送状態が繰り返し失われました。名刺の位置を調整して再スキャンしてください。"
        case .chargingTimeout: return "充電が完了しませんでした。名刺の位置を調整して再スキャンしてください。"
        case .firmwareRestarted: return "名刺の電源断を検出しました。同じ名刺を再スキャンしてください。"
        }
    }
}

/// Timings are upper bounds measured for the sold board/panel/cover configuration,
/// including all firmware-managed stages and charging after the first EXECUTE.
/// A nil route remains disabled, even when another route has been validated.
public struct HardwareProfile: Sendable, Equatable {
    public let validationReference: String?
    public let normalRefreshSeconds: TimeInterval?
    public let batchRefreshSeconds: TimeInterval?
    public let legacyRefreshSeconds: TimeInterval?
    public let grayTransitionRefreshSeconds: TimeInterval?
    public let isDeveloperTesting: Bool

    public static let unvalidated = HardwareProfile()

    private init() {
        validationReference = nil
        normalRefreshSeconds = nil
        batchRefreshSeconds = nil
        legacyRefreshSeconds = nil
        grayTransitionRefreshSeconds = nil
        isDeveloperTesting = false
    }

    public init(validationReference: String, normalRefreshSeconds: TimeInterval,
                batchRefreshSeconds: TimeInterval? = nil,
                legacyRefreshSeconds: TimeInterval? = nil,
                grayTransitionRefreshSeconds: TimeInterval? = nil) throws {
        let values = [normalRefreshSeconds, batchRefreshSeconds, legacyRefreshSeconds,
                      grayTransitionRefreshSeconds].compactMap { $0 }
        guard !validationReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              values.allSatisfy({ $0.isFinite && $0 >= 2.25 && $0 < 55 }) else {
            throw TransferError.invalidMeasurement
        }
        self.validationReference = validationReference
        self.normalRefreshSeconds = normalRefreshSeconds
        self.batchRefreshSeconds = batchRefreshSeconds
        self.legacyRefreshSeconds = legacyRefreshSeconds
        self.grayTransitionRefreshSeconds = grayTransitionRefreshSeconds
        isDeveloperTesting = false
    }

    /// Bench testing only. These 8/20/8-second budgets are provisional, NOT
    /// hardware measurements. Gray-to-mono transitions remain disabled.
    /// The app references this only under HARDWARE_TESTING. Xcode builds local
    /// packages as Release for custom configurations, so this factory must be
    /// available independently of the package's DEBUG condition.
    public static var developerTesting: HardwareProfile {
        HardwareProfile(development: true)
    }
    private init(development: Bool) {
        validationReference = nil
        normalRefreshSeconds = 8
        batchRefreshSeconds = 20
        legacyRefreshSeconds = 8
        grayTransitionRefreshSeconds = nil
        isDeveloperTesting = development
    }

    func duration(for route: TransferRoute) throws -> TimeInterval {
        guard validationReference != nil || isDeveloperTesting else {
            throw TransferError.unvalidatedHardware
        }
        let duration: TimeInterval?
        switch route {
        case .normal: duration = normalRefreshSeconds
        case .batch: duration = batchRefreshSeconds
        case .legacy: duration = legacyRefreshSeconds
        case .grayTransition: duration = grayTransitionRefreshSeconds
        }
        guard let duration else { throw TransferError.unvalidatedRoute(route.rawValue) }
        return duration
    }
}

enum TransferRoute: String { case normal = "通常白黒", batch = "FW一括クリーニング", legacy = "旧FWクリーニング", grayTransition = "4階調からの移行" }

public enum TransferJob: Sendable, Equatable {
    case image(Data, cleanBeforeWrite: Bool)
    case pattern(UInt8)
    case sequence
    case status
}

public struct TransferSnapshot: Sendable {
    public let job: TransferJob
    public let uid: Data?
    public let transferID: UInt16?
    public let expectedSequence: UInt16
    public let expectedOffset: UInt16
    public let lastAck: NCAck?
    public let unconfirmedCommand: NCFrame?
    public let executeSent: Bool
    public let executeAcknowledged: Bool
    public let refreshMayBeActive: Bool
    public let nextPattern: Int
}

public struct TransferProgress: Sendable {
    public enum Phase: String, Sendable { case starting, diagnostic, cleaning, sending, charging, refreshing, completed, resumeRequired }
    public let phase: Phase
    public let message: String
    public let completedBytes: Int
    public let totalBytes: Int
    public let pattern: Int?
    public var fraction: Double { totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0 }
}

public enum TransferOutcome: Sendable {
    case completed(NCAck)
    /// It is safe for the adapter to end this session. The job remains in RAM.
    case resumeNeeded(String)
    /// EXECUTE may be active. Leave the RF field/session alive until Core NFC
    /// invalidates it; never implement a timer that invalidates an active refresh.
    case holdField(String)
}
