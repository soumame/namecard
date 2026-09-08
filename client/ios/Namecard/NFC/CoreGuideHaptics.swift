import CoreHaptics
import Foundation
import NamecardCore

@MainActor
protocol GuideHapticEngine: AnyObject {
    var interrupted: ((String) -> Void)? { get set }
    func start(_ completion: @escaping (Error?) -> Void)
    func play(_ pulse: LinkFeedback.Pulse) throws
    func cancelPlayback()
    func stop()
}

@MainActor
private final class DeviceGuideHapticEngine: GuideHapticEngine {
    var interrupted: ((String) -> Void)?
    private let engine: CHHapticEngine
    private var player: (any CHHapticPatternPlayer)?

    init() throws {
        let trace = PerformanceTrace.begin("Haptics.init")
        defer { PerformanceTrace.end(trace) }
        engine = try CHHapticEngine()
        engine.playsHapticsOnly = true
        engine.stoppedHandler = { [weak self] reason in
            Task { @MainActor in self?.interrupted?("stopped reason=\(reason.rawValue)") }
        }
        engine.resetHandler = { [weak self] in
            Task { @MainActor in self?.interrupted?("reset") }
        }
    }

    func start(_ completion: @escaping (Error?) -> Void) {
        let trace = PerformanceTrace.begin("Haptics.requestStart")
        defer { PerformanceTrace.end(trace) }
        engine.start { error in Task { @MainActor in completion(error) } }
    }

    func play(_ pulse: LinkFeedback.Pulse) throws {
        let trace = PerformanceTrace.begin("Haptics.play")
        defer { PerformanceTrace.end(trace) }
        let intensity: Float
        let sharpness: Float
        switch pulse {
        case .gentle: intensity = 0.25; sharpness = 0.3
        case .approaching: intensity = 0.45; sharpness = 0.3
        case .locked: intensity = 0.65; sharpness = 0.7
        }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: 0)
        player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
        try player?.start(atTime: CHHapticTimeImmediate)
    }

    func cancelPlayback() {
        guard let player else { return }
        let trace = PerformanceTrace.begin("Haptics.cancelPlayback")
        defer { PerformanceTrace.end(trace) }
        try? player.stop(atTime: CHHapticTimeImmediate)
        self.player = nil
    }
    func stop() {
        let trace = PerformanceTrace.begin("Haptics.stop")
        defer { PerformanceTrace.end(trace) }
        cancelPlayback()
        interrupted = nil
        engine.stoppedHandler = { _ in }
        engine.resetHandler = {}
        engine.stop(completionHandler: nil)
    }
}

/// Does not await engine startup on the RF path. Synchronous SDK calls are
/// measured separately. Only a fresh, uncancelled pulse may play after startup;
/// OS interruption and startup failures are observable.
@MainActor
final class CoreGuideHaptics: GuideHapticOutput {
    let supported: Bool
    var onEvent: ((String) -> Void)?
    private let makeEngine: () throws -> any GuideHapticEngine
    private let now: () -> TimeInterval
    private var engine: (any GuideHapticEngine)?
    private var ready = false
    private var generation = UUID()
    private var attempts = 0
    private var limitReported = false
    private var pending: (LinkFeedback.Pulse, TimeInterval)?
    private var startupWatchdog: Task<Void, Never>?

    init(supported: Bool = CHHapticEngine.capabilitiesForHardware().supportsHaptics,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makeEngine: (() throws -> any GuideHapticEngine)? = nil) {
        self.supported = supported
        self.now = now
        self.makeEngine = makeEngine ?? { try DeviceGuideHapticEngine() }
    }

    func prepare() {
        guard supported, engine == nil, attempts < 3 else { return }
        attempts += 1
        let token = UUID()
        generation = token
        do {
            let created = try makeEngine()
            engine = created
            created.interrupted = { [weak self] reason in
                guard let self, self.generation == token else { return }
                self.onEvent?("CoreHaptics \(reason)。次の新しい案内時に再起動します（上限3回）。")
                self.discardEngine()
            }
            onEvent?("CoreHaptics 起動要求 \(attempts)/3")
            startupWatchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.generation == token, !self.ready else { return }
                self.onEvent?("CoreHaptics 起動タイムアウト")
                self.discardEngine()
            }
            created.start { [weak self, weak created] error in
                guard let self, self.generation == token else {
                    created?.stop() // A late SDK completion must not leave an old engine running.
                    return
                }
                self.startupWatchdog?.cancel()
                self.startupWatchdog = nil
                if let error {
                    self.onEvent?("CoreHaptics 起動失敗: \(Self.detail(error))")
                    self.discardEngine()
                    return
                }
                self.ready = true
                self.onEvent?("CoreHaptics 起動完了")
                self.flush()
            }
        } catch {
            onEvent?("CoreHaptics 初期化失敗: \(Self.detail(error))")
            discardEngine()
        }
    }

    func play(_ pulse: LinkFeedback.Pulse) {
        guard supported else { onEvent?("CoreHaptics 非対応"); return }
        guard attempts < 3 || engine != nil else {
            if !limitReported { onEvent?("CoreHaptics 起動上限に達したため、この接続での振動を停止") }
            limitReported = true
            return
        }
        pending = (pulse, now())
        prepare()
        flush()
    }

    func cancelPending() {
        pending = nil
        engine?.cancelPlayback()
    }

    func stop() {
        discardEngine()
        attempts = 0
        limitReported = false
    }

    private func flush() {
        guard ready, let engine, let (pulse, requestedAt) = pending else { return }
        pending = nil
        guard now() - requestedAt <= 0.5 else {
            onEvent?("CoreHaptics 古い振動要求を破棄（起動待ちが0.5秒超）")
            return
        }
        do {
            try engine.play(pulse)
            onEvent?("CoreHaptics 再生開始 \(pulse)（実際の振動は端末で確認）")
        } catch {
            onEvent?("CoreHaptics 再生失敗: \(Self.detail(error))")
            discardEngine()
        }
    }

    private func discardEngine() {
        generation = UUID()
        ready = false
        pending = nil
        startupWatchdog?.cancel()
        startupWatchdog = nil
        let old = engine
        engine = nil
        old?.stop()
    }

    private static func detail(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain)(\(error.code)) \(error.localizedDescription)"
    }
}
