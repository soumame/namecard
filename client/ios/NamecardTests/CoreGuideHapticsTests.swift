import Foundation
import NamecardCore
import XCTest
@testable import Namecard

@MainActor
private final class ManualHapticEngine: GuideHapticEngine {
    var interrupted: ((String) -> Void)?
    var completion: ((Error?) -> Void)?
    var pulses: [LinkFeedback.Pulse] = []
    var stops = 0
    var playbackError: Error?
    func start(_ completion: @escaping (Error?) -> Void) { self.completion = completion }
    func play(_ pulse: LinkFeedback.Pulse) throws {
        if let playbackError { throw playbackError }
        pulses.append(pulse)
    }
    func cancelPlayback() {}
    func stop() { stops += 1 }
}

@MainActor
final class CoreGuideHapticsTests: XCTestCase {
    func testAsyncStartupPlaysOneFreshPulseWithoutWaitingInCaller() {
        let engine = ManualHapticEngine()
        let output = CoreGuideHaptics(supported: true, now: { 0 }, makeEngine: { engine })
        defer { output.stop() }
        var events: [String] = []
        output.onEvent = { events.append($0) }
        output.prepare()
        output.play(.locked)
        XCTAssertTrue(engine.pulses.isEmpty)
        engine.completion?(nil)
        XCTAssertEqual(engine.pulses, [.locked])
        XCTAssertTrue(events.contains { $0.contains("起動完了") })
        XCTAssertTrue(events.contains { $0.contains("再生開始 locked") })
    }

    func testExecuteOrStaleSampleCancellationDiscardsQueuedPulseDuringStartup() {
        let engine = ManualHapticEngine()
        let output = CoreGuideHaptics(supported: true, now: { 0 }, makeEngine: { engine })
        defer { output.stop() }
        output.play(.locked)
        output.cancelPending() // EXECUTE / COMMIT / weak / stale sample
        engine.completion?(nil)
        XCTAssertTrue(engine.pulses.isEmpty)
    }

    func testStopAndNewSessionIgnoreOldEngineStartupAndInterruptions() {
        let old = ManualHapticEngine(), current = ManualHapticEngine()
        var engines = [old, current]
        let output = CoreGuideHaptics(supported: true, now: { 0 }, makeEngine: { engines.removeFirst() })
        defer { output.stop() }
        output.play(.locked)
        let oldInterruption = old.interrupted
        output.stop()
        output.play(.gentle)
        old.completion?(nil)
        oldInterruption?("late interruption")
        XCTAssertTrue(old.pulses.isEmpty)
        XCTAssertGreaterThanOrEqual(old.stops, 2)
        current.completion?(nil)
        XCTAssertEqual(current.pulses, [.gentle])
    }

    func testSlowStartupDropsExpiredPulseInsteadOfPlayingOldGoodHint() {
        let engine = ManualHapticEngine()
        var now: TimeInterval = 0
        let output = CoreGuideHaptics(supported: true, now: { now }, makeEngine: { engine })
        defer { output.stop() }
        var events: [String] = []
        output.onEvent = { events.append($0) }
        output.play(.locked)
        now = 0.6
        engine.completion?(nil)
        XCTAssertTrue(engine.pulses.isEmpty)
        XCTAssertTrue(events.contains { $0.contains("古い振動要求を破棄") })
        output.play(.gentle)
        XCTAssertEqual(engine.pulses, [.gentle])
    }

    func testFailuresAreLoggedAndEngineRestartsAreBounded() {
        let engines = (0..<3).map { _ in ManualHapticEngine() }
        var creations = 0
        let output = CoreGuideHaptics(supported: true, now: { 0 }, makeEngine: {
            defer { creations += 1 }
            return engines[creations]
        })
        defer { output.stop() }
        var events: [String] = []
        output.onEvent = { events.append($0) }
        let failure = NSError(domain: "HapticTest", code: 42)
        output.play(.gentle)
        engines[0].completion?(failure)
        output.play(.gentle)
        engines[1].completion?(nil)
        engines[1].interrupted?("audioSessionInterrupt")
        output.play(.locked)
        engines[2].playbackError = failure
        engines[2].completion?(nil)
        for _ in 0..<10 { output.play(.gentle) }
        XCTAssertEqual(creations, 3)
        XCTAssertTrue(events.contains { $0.contains("起動失敗: HapticTest(42)") })
        XCTAssertTrue(events.contains { $0.contains("audioSessionInterrupt") })
        XCTAssertTrue(events.contains { $0.contains("再生失敗: HapticTest(42)") })
    }
}
