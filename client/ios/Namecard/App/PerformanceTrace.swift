import Foundation
import os

/// Measures synchronous work, not asynchronous NFC/EPD waiting time. Never logs
/// entered text, image bytes or tag identifiers. Instruments can correlate the
/// intervals with a main-thread hang even when no single interval exceeds 100 ms.
enum PerformanceTrace {
    private static let logger = Logger(subsystem: "jp.namecard.ios", category: "Performance")
    private static let signposter = OSSignposter(logger: logger)

    struct Interval {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
        fileprivate let startedAt: TimeInterval
        fileprivate let onMainThread: Bool
    }

    static func begin(_ name: StaticString) -> Interval {
        Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()),
                 startedAt: ProcessInfo.processInfo.systemUptime, onMainThread: Thread.isMainThread)
    }

    static func end(_ interval: Interval) {
        let elapsed = ProcessInfo.processInfo.systemUptime - interval.startedAt
        signposter.endInterval(interval.name, interval.state)
        if elapsed >= 0.1 {
            logger.notice("[Performance] \(String(describing: interval.name), privacy: .public) \(Int(elapsed * 1000))ms main=\(interval.onMainThread)")
        }
    }

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}
