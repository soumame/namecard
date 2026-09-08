import Foundation
import NamecardCore
import XCTest
@testable import Namecard

@MainActor
private final class RecordedHaptics: GuideHapticOutput {
    var supported = true
    var onEvent: ((String) -> Void)?
    var pulses: [LinkFeedback.Pulse] = []
    var cancellations = 0
    var stops = 0
    func prepare() {}
    func play(_ pulse: LinkFeedback.Pulse) { pulses.append(pulse) }
    func cancelPending() { cancellations += 1 }
    func stop() { stops += 1 }
}

private actor FeedbackTransport: MailboxTransport {
    let action: @Sendable (NCFrame) async throws -> NCAck
    var requests: [NCFrame] = []
    var timeouts: [TimeInterval] = []
    init(action: @escaping @Sendable (NCFrame) async throws -> NCAck) { self.action = action }
    func exchange(_ frame: NCFrame, timeout: TimeInterval) async throws -> NCAck {
        requests.append(frame)
        timeouts.append(timeout)
        return try await action(frame)
    }
}

@MainActor
final class NFCHapticGuideTests: XCTestCase {
    private var settings: UserDefaults!
    private var suite: String!
    override func setUp() {
        suite = "NamecardHapticTest.\(UUID())"
        settings = UserDefaults(suiteName: suite)!
    }
    override func tearDown() { settings.removePersistentDomain(forName: suite) }

    func testDefaultOffPreferencePreviewAndDisableStopPendingFeedback() throws {
        let output = RecordedHaptics()
        let guide = NFCHapticGuide(settings: settings, output: output)
        defer { guide.stop() }
        XCTAssertFalse(guide.enabled)
        guide.preview()
        XCTAssertTrue(output.pulses.isEmpty)
        guide.enabled = true
        XCTAssertTrue(NFCHapticGuide(settings: settings, output: output).enabled)
        guide.preview()
        XCTAssertEqual(output.pulses, [.locked])
        let token = UUID()
        guide.begin(connection: token)
        try feed(guide, connection: token)
        guide.enabled = false
        guide.tick(now: 0.6)
        guide.received(try Self.ack(), elapsed: 0.1, now: 1, connection: token)
        XCTAssertEqual(output.pulses, [.locked])
        XCTAssertEqual(guide.state, .idle)
    }

    func testStoppedAndOldConnectionCallbacksCannotAffectNewScan() throws {
        let output = RecordedHaptics()
        let guide = NFCHapticGuide(settings: settings, output: output)
        defer { guide.stop() }
        guide.enabled = true
        let old = UUID(), current = UUID()
        guide.begin(connection: old)
        try feed(guide, connection: old)
        guide.stop() // completion, invalidation, background or terminal error
        guide.tick(now: 0.6)
        XCTAssertTrue(output.pulses.isEmpty)
        guide.begin(connection: current)
        try feed(guide, connection: old)
        guide.willSend(NCFrame(command: .execute, transferID: 1), connection: old)
        guide.failed(connection: old)
        guide.tick(now: 1)
        XCTAssertEqual(guide.state, .waiting)
        XCTAssertTrue(output.pulses.isEmpty)
        try feed(guide, connection: current)
        guide.tick(now: 0.6)
        XCTAssertEqual(output.pulses, [.locked])
        guide.tick(now: 2.2)
        XCTAssertEqual(guide.state, .waiting)
        XCTAssertEqual(output.pulses, [.locked])
    }

    func testUnsupportedDeviceDoesNotAttemptPreviewOrStart() throws {
        let output = RecordedHaptics()
        output.supported = false
        let guide = NFCHapticGuide(settings: settings, output: output)
        guide.enabled = true
        let token = UUID()
        guide.begin(connection: token)
        try feed(guide, connection: token)
        guide.preview()
        guide.tick(now: 0.6)
        XCTAssertEqual(guide.state, .idle)
        XCTAssertTrue(output.pulses.isEmpty)
    }

    func testDiagnosticsDistinguishNoQualifyingSamplesFromPlaybackRequests() throws {
        let output = RecordedHaptics()
        let guide = NFCHapticGuide(settings: settings, output: output)
        guide.enabled = true
        var events: [String] = []
        guide.onEvent = { events.append($0) }
        let token = UUID()
        guide.begin(connection: token)
        guide.received(try Self.ack(), elapsed: 0.9, now: 0, connection: token)
        guide.tick(now: 0.1)
        guide.stop()
        XCTAssertTrue(events.contains { $0.contains("判定=weak") && $0.contains("応答=900ms") })
        XCTAssertTrue(events.contains { $0.contains("案内終了: 再生要求=0") })
        events.removeAll()
        guide.begin(connection: token)
        try feed(guide, connection: token)
        guide.tick(now: 0.6)
        XCTAssertTrue(events.contains { $0.contains("再生要求 #1 locked") })
        let cancellations = output.cancellations
        guide.willSend(NCFrame(command: .execute, transferID: 1), connection: token)
        XCTAssertGreaterThan(output.cancellations, cancellations)
        guide.stop()
        XCTAssertTrue(events.contains { $0.contains("案内終了: 再生要求=1") })
    }

    func testAdapterForwardsOneUnmodifiedExchangeAndPausesBeforeLostExecuteACK() async throws {
        let output = RecordedHaptics()
        let guide = NFCHapticGuide(settings: settings, output: output)
        defer { guide.stop() }
        guide.enabled = true
        let token = UUID()
        guide.begin(connection: token)
        let backing = FeedbackTransport { frame in
            if frame.type == NCCommand.execute.rawValue {
                let state = await guide.state
                XCTAssertEqual(state, .updating, "Must silence before starting the RF request")
                throw MailboxTransportError.connectionLost("EXECUTE applied but ACK lost")
            }
            return try Self.ack()
        }
        let transport = FeedbackMailbox(transport: backing, guide: guide, connection: token)
        let status = NCFrame(command: .status, transferID: 1)
        let ack = try await transport.exchange(status, timeout: 1.25)
        XCTAssertEqual(ack.vddMV, 3250)
        try feed(guide, connection: token)
        let execute = NCFrame(command: .execute, transferID: 1, sequence: 39, offset: 4736)
        do {
            _ = try await transport.exchange(execute, timeout: 1.5)
            XCTFail("Expected original transport error")
        } catch MailboxTransportError.connectionLost { }
        guide.tick(now: 1)
        XCTAssertTrue(output.pulses.isEmpty)
        XCTAssertEqual(guide.state, .updating)
        let frames = await backing.requests
        let timeouts = await backing.timeouts
        XCTAssertEqual(frames, [status, execute], "Feedback must not issue extra requests or retry")
        XCTAssertEqual(timeouts, [1.25, 1.5])
    }

    private func feed(_ guide: NFCHapticGuide, connection: UUID) throws {
        for now in [0.0, 0.3, 0.6] {
            guide.received(try Self.ack(), elapsed: 0.1, now: now, connection: connection)
        }
    }

    nonisolated private static func ack() throws -> NCAck {
        let request = NCFrame(command: .status, transferID: 1)
        let payload = Data([4, 2, 1, 0, 0, 0, 0, 0, 0xb2, 0x0c, 0, 0, 0, 0, 0, 0])
        var bytes = try NCFrame(command: .status, transferID: 1, payload: payload).encoded()
        bytes[3] = 0x80
        let crc = NCCRC.crc16(bytes.prefix(12) + bytes[14..<16])
        bytes[12] = UInt8(truncatingIfNeeded: crc); bytes[13] = UInt8(crc >> 8)
        return try NCAck(data: bytes, request: request)
    }
}
