import Foundation

/// A placement hint, not RSSI or a guarantee that an EPD update will succeed.
/// Consumes existing command/ACK events only. Thresholds are provisional.
public struct LinkFeedback: Sendable {
    public enum State: String, Sendable {
        case idle, waiting, weak, settling, stable, updating
    }
    public enum Pulse: Sendable, Equatable { case gentle, approaching, locked }
    public private(set) var state: State = .idle
    private var active = false
    private var updateStarted = false
    private var lastSample: TimeInterval?
    private var goodSince: TimeInterval?
    private var goodCount = 0
    private var lastFailure: TimeInterval = -.infinity
    private var lastPulse: TimeInterval = -.infinity
    private var announcedStable = false
    private var strong = false
    public static let sampleLifetime: TimeInterval = 1.5

    public init() {}

    public mutating func begin() {
        self = Self()
        active = true
        state = .waiting
    }

    public mutating func end() { self = Self() }

    /// Must run before forwarding the RF request, including an EXECUTE whose ACK is lost.
    public mutating func willSend(_ command: NCCommand) {
        guard active else { return }
        switch command {
        case .execute:
            updateStarted = true
            clearSample()
            state = .updating
        case .start, .pattern:
            updateStarted = false
            clearSample()
            state = .waiting
        case .commit, .ndefWritePrepare:
            clearSample()
            state = updateStarted ? .updating : .waiting
        case .data, .status: break
        }
    }

    public mutating func receive(_ ack: NCAck, responseSeconds: TimeInterval, now: TimeInterval) {
        guard active else { return }
        if ack.acknowledgedType == NCCommand.execute.rawValue || ack.state == 4 || ack.state == 5 {
            updateStarted = true
        }
        guard !updateStarted else { clearSample(); state = .updating; return }
        guard ack.error == 0, ack.code != 0x80, ack.quietMS == 0,
              [NCCommand.start, .data, .pattern, .status].contains(where: { $0.rawValue == ack.acknowledgedType }),
              [1, 2, 3].contains(ack.state), ack.vddMV > 0,
              responseSeconds.isFinite, responseSeconds >= 0 else {
            clearSample()
            state = .waiting
            return
        }
        if let lastSample, now - lastSample >= Self.sampleLifetime { clearSample() }
        lastSample = now
        strong = ack.vddMV >= 3200 && responseSeconds < 0.35
        if ack.vddMV < 3050 || responseSeconds >= 0.8 || now - lastFailure < 2 {
            resetGoodRun()
            state = .weak
        } else if strong {
            if goodSince == nil { goodSince = now }
            goodCount += 1
            state = goodCount >= 3 && now - (goodSince ?? now) >= 0.5 ? .stable : .settling
        } else {
            resetGoodRun()
            state = .settling
        }
    }

    public mutating func failed(now: TimeInterval) {
        guard active else { return }
        lastFailure = now
        clearSample()
        state = updateStarted ? .updating : .waiting
    }

    public mutating func expire(now: TimeInterval) {
        guard active, !updateStarted, let lastSample, now - lastSample >= Self.sampleLifetime else { return }
        clearSample()
        state = .waiting
    }

    public mutating func pulse(now: TimeInterval) -> Pulse? {
        expire(now: now)
        guard active, !updateStarted, lastSample != nil else { return nil }
        let pulse: Pulse
        let interval: TimeInterval
        switch state {
        case .settling:
            pulse = strong ? .approaching : .gentle
            interval = strong ? 0.75 : 1.2
        case .stable:
            pulse = announcedStable ? .gentle : .locked
            interval = announcedStable ? 2 : 0.6
        default: return nil
        }
        guard now - lastPulse >= interval else { return nil }
        lastPulse = now
        if pulse == .locked { announcedStable = true }
        return pulse
    }

    private mutating func resetGoodRun() {
        goodCount = 0
        goodSince = nil
        announcedStable = false
    }
    private mutating func clearSample() {
        lastSample = nil
        strong = false
        resetGoodRun()
    }
}
