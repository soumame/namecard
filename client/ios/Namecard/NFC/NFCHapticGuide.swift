import Foundation
import NamecardCore
import Observation

@MainActor
protocol GuideHapticOutput: AnyObject {
    var supported: Bool { get }
    var onEvent: ((String) -> Void)? { get set }
    func prepare()
    func play(_ pulse: LinkFeedback.Pulse)
    func cancelPending()
    func stop()
}

@MainActor @Observable
final class NFCHapticGuide {
    var enabled: Bool {
        didSet {
            settings.set(enabled, forKey: Self.preferenceKey)
            if !enabled { stop() }
        }
    }
    private(set) var state: LinkFeedback.State = .idle
    var supported: Bool { output.supported }
    var explanation: String {
        guard supported else { return "この環境では振動を利用できません" }
        guard enabled else { return "振動による位置案内はOFFです" }
        switch state {
        case .idle: return "書き込み中に振動で案内します"
        case .waiting: return "応答待ち・振動を停止しています"
        case .weak: return "通信が不安定です。位置を保って様子を見てください"
        case .settling: return "電源と応答を確認中です"
        case .stable: return "通信が安定しています。その位置を保ってください"
        case .updating: return "表示更新中は振動を止めます。そのまま固定してください"
        }
    }
    static let preferenceKey = "nfcPlacementHapticsEnabled"
    @ObservationIgnored private let settings: UserDefaults
    @ObservationIgnored private let output: any GuideHapticOutput
    @ObservationIgnored private var policy = LinkFeedback()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var connection: UUID?
    @ObservationIgnored var onEvent: ((String) -> Void)?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var requestCount = 0
    @ObservationIgnored private var lastSample = "ACKなし"
    @ObservationIgnored private var lastDiagnostic: TimeInterval = -.infinity

    init(settings: UserDefaults = .standard, output: (any GuideHapticOutput)? = nil) {
        self.settings = settings
        self.output = output ?? CoreGuideHaptics()
        enabled = settings.bool(forKey: Self.preferenceKey)
        self.output.onEvent = { [weak self] message in self?.onEvent?(message) }
    }

    func begin(connection: UUID) {
        stop()
        guard enabled, supported else { return }
        self.connection = connection
        requestCount = 0
        lastSample = "ACKなし"
        lastDiagnostic = -.infinity
        policy.begin()
        state = policy.state
        onEvent?("案内開始。VDD・応答時間から判定")
        output.prepare()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard !Task.isCancelled, let self, self.connection == connection else { return }
                self.tick(now: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    func willSend(_ frame: NCFrame, connection: UUID) {
        guard self.connection == connection, let command = NCCommand(rawValue: frame.type) else { return }
        policy.willSend(command)
        updateState()
        if command == .execute || command == .commit {
            onEvent?("NC=\(command.rawValue)送信前に振動停止")
        }
    }

    func received(_ ack: NCAck, elapsed: TimeInterval, now: TimeInterval, connection: UUID) {
        guard self.connection == connection else { return }
        policy.receive(ack, responseSeconds: elapsed, now: now)
        let response = elapsed.isFinite ? String(format: "%.0f", elapsed * 1000) : "--"
        lastSample = "NC=\(ack.acknowledgedType) state=\(ack.state) VDD=\(ack.vddMV) 応答=\(response)ms quiet=\(ack.quietMS) error=\(ack.error)"
        let changed = state != policy.state
        updateState()
        if changed || now - lastDiagnostic >= 2 {
            onEvent?("判定=\(policy.state.rawValue) \(lastSample) 再生要求=\(requestCount)")
            lastDiagnostic = now
        }
    }

    func failed(connection: UUID) {
        guard self.connection == connection else { return }
        policy.failed(now: ProcessInfo.processInfo.systemUptime)
        updateState()
        onEvent?("通信失敗で案内を停止。判定=\(state.rawValue)")
    }

    func stop() {
        if connection != nil { onEvent?("案内終了: 再生要求=\(requestCount) 判定=\(state.rawValue) \(lastSample)") }
        ticker?.cancel()
        ticker = nil
        previewTask?.cancel()
        previewTask = nil
        connection = nil
        output.stop()
        policy.end()
        state = .idle
    }

    func preview() {
        guard enabled, supported, connection == nil else { return }
        stop()
        output.play(.locked)
        previewTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled, let self, self.connection == nil else { return }
            self.output.stop()
        }
    }

    // Internal for deterministic lifecycle tests; production ticks use uptime.
    func tick(now: TimeInterval) {
        guard enabled, connection != nil else { return }
        let previous = state
        let pulse = policy.pulse(now: now)
        updateState()
        if previous != .waiting && state == .waiting {
            onEvent?("有効な応答が1.5秒以上届かないため振動停止")
        }
        if let pulse {
            requestCount += 1
            onEvent?("再生要求 #\(requestCount) \(pulse)")
            output.play(pulse)
        }
    }

    private func updateState() {
        if state != policy.state { state = policy.state }
        if state != .settling && state != .stable { output.cancelPending() }
    }
}

/// Await the hint update before RF I/O so EXECUTE ACK loss cannot leave pulses running.
/// This adapter never issues extra commands, retries, or changes the ACK.
struct FeedbackMailbox: MailboxTransport {
    let transport: any MailboxTransport
    let guide: NFCHapticGuide
    let connection: UUID

    func exchange(_ frame: NCFrame, timeout: TimeInterval) async throws -> NCAck {
        try Task.checkCancellation()
        await guide.willSend(frame, connection: connection)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let ack = try await transport.exchange(frame, timeout: timeout)
            try Task.checkCancellation()
            let received = ProcessInfo.processInfo.systemUptime
            await guide.received(ack, elapsed: received - started, now: received, connection: connection)
            return ack
        } catch {
            await guide.failed(connection: connection)
            throw error
        }
    }
}
