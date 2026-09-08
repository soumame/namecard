import Foundation
import XCTest
@testable import NamecardCore

private actor TransferTestClock: TransferClock {
    var time: TimeInterval = 0
    var pauses: [TimeInterval] = []
    func now() -> TimeInterval { time }
    func sleep(seconds: TimeInterval) throws {
        try Task.checkCancellation()
        pauses.append(seconds); time += seconds
    }
    func advance(_ seconds: TimeInterval) { time += seconds }
}

private enum MockLinkError: Error { case disconnected }

/// Deterministic model of nc_transfer_apply and the app's charge/refresh states.
/// Wire ACKs go through the production CRC/context/position validator.
private actor TransferMockMailbox: MailboxTransport {
    struct Configuration: Sendable {
        var batchSupported = true
        var voltage: UInt16 = 3_250
        var initialState: UInt8 = 1
        var extraCapabilities: UInt8 = 0
        var dropDataOffset: UInt16?
        var rejectTransferOffset: UInt16?
        var rewindAtOffset: UInt16?
        var forwardAtOffset: UInt16?
        var staleAtOffset: UInt16?
        var loseExecuteNumber: Int?
        var chargeNeverReady = false
        var deferExecuteCount = 0
        var refreshNeverCompletes = false
        var wrongCompletePosition = false
    }
    struct Event: Sendable { let frame: NCFrame; let time: TimeInterval }
    private let clock: TransferTestClock
    private var config: Configuration
    private var activeID: UInt16?
    private var sequence: UInt16 = 0
    private var offset: UInt16 = 0
    private var state: UInt8
    private var lastAccepted: NCFrame?
    private var image = Data()
    private var batchActive = false
    private var stagesRemaining = 0
    private var executes = 0
    private var restoredChargeStatusOnce = false
    private(set) var events: [Event] = []
    private(set) var duplicates = 0
    private(set) var completedPatterns: [UInt8] = []
    private var pattern: UInt8?

    func receivedImage() -> Data { image }

    init(clock: TransferTestClock, configuration: Configuration = Configuration()) {
        self.clock = clock; config = configuration; state = configuration.initialState
    }

    func simulateLossOfRAMBeforeExecute() {
        activeID = nil; sequence = 0; offset = 0; state = 1
        lastAccepted = nil; image = Data(); batchActive = false; stagesRemaining = 0
    }

    func restorePendingWithoutDuplicateCache() {
        // app.c restores transfer ID/sequence/image from Flash but not the
        // last accepted RF frame used by nc_transfer_apply's duplicate check.
        lastAccepted = nil
        state = 2
    }

    func simulateRestoredOlderPending(sequence: UInt16, offset: UInt16, reportChargingOnce: Bool = false) {
        activeID = 999; self.sequence = sequence; self.offset = offset; state = 2
        lastAccepted = nil; image = Data(repeating: 0xff, count: 4_736)
        batchActive = false; stagesRemaining = 1
        restoredChargeStatusOnce = reportChargingOnce
    }

    func exchange(_ frame: NCFrame, timeout: TimeInterval) async throws -> NCAck {
        events.append(Event(frame: frame, time: await clock.now()))
        await clock.advance(0.05) // ACK settle time; no wall-clock sleeps in tests.
        let command = NCCommand(rawValue: frame.type)!
        if command == .status {
            if state == 2 && !config.chargeNeverReady {
                if restoredChargeStatusOnce { restoredChargeStatusOnce = false }
                else { state = 3 }
            }
            if state == 4 || state == 5 {
                if config.refreshNeverCompletes { state = 5 }
                else if stagesRemaining > 0 { state = 3 }
                else {
                    state = 6
                    if let pattern { completedPatterns.append(pattern); self.pattern = nil }
                }
            }
            if state == 6 && config.wrongCompletePosition && executes > 0 {
                return try ack(frame, expectedSequence: sequence + 1)
            }
            return try ack(frame)
        }
        if command == .data, config.rejectTransferOffset == frame.offset {
            config.rejectTransferOffset = nil
            activeID = nil; sequence = 0; offset = 0; state = 1
            return try ack(frame, error: 7)
        }
        if command == .data, config.rewindAtOffset == frame.offset {
            config.rewindAtOffset = nil
            offset = frame.offset - 128; sequence = 1 + offset / 128
            image = image.prefix(Int(offset)); lastAccepted = nil
            return try ack(frame, error: 8)
        }
        if command == .data, config.forwardAtOffset == frame.offset {
            config.forwardAtOffset = nil
            return try ack(frame, error: 9, expectedSequence: sequence + 3, expectedOffset: frame.offset + 384)
        }
        if command == .data, config.staleAtOffset == frame.offset {
            config.staleAtOffset = nil
            let old = NCFrame(command: .data, transferID: frame.transferID, sequence: frame.sequence - 1,
                              offset: frame.offset - 128, payload: frame.payload)
            return try ack(old, expectedSequence: frame.sequence, expectedOffset: frame.offset)
        }
        if command != .start && command != .pattern && activeID != frame.transferID {
            return try ack(frame, error: 7)
        }
        if frame == lastAccepted && command != .execute {
            duplicates += 1
            return try ack(frame, duplicate: true)
        }
        switch command {
        case .start:
            activeID = frame.transferID; sequence = 1; offset = 0; state = 1
            image = Data(); pattern = nil
            batchActive = frame.payload[12] & 1 != 0
            stagesRemaining = batchActive ? 4 : 1
        case .pattern:
            activeID = frame.transferID; sequence = 1; offset = 4_736; state = 2
            batchActive = false; stagesRemaining = 1; pattern = frame.payload[0]
        case .data:
            guard frame.sequence == sequence else { return try ack(frame, error: 8) }
            guard frame.offset == offset else { return try ack(frame, error: 9) }
            image.append(frame.payload); offset += UInt16(frame.payload.count); sequence += 1
        case .commit:
            guard frame.sequence == sequence else { return try ack(frame, error: 8) }
            guard frame.offset == offset else { return try ack(frame, error: 9) }
            sequence += 1; state = 2
        case .execute:
            if config.deferExecuteCount > 0 {
                config.deferExecuteCount -= 1; state = 2
                return try ack(frame)
            }
            guard frame.sequence == sequence else { return try ack(frame, error: 8) }
            sequence += 1; state = 4; stagesRemaining -= 1; executes += 1
            if config.loseExecuteNumber == executes {
                config.loseExecuteNumber = nil
                throw MockLinkError.disconnected
            }
        case .status, .ndefWritePrepare: break
        }
        lastAccepted = frame
        if command == .data && config.dropDataOffset == frame.offset {
            config.dropDataOffset = nil
            throw MockLinkError.disconnected
        }
        return try ack(frame)
    }

    private func ack(_ request: NCFrame, duplicate: Bool = false, error: UInt8 = 0,
                     expectedSequence: UInt16? = nil, expectedOffset: UInt16? = nil) throws -> NCAck {
        let seq = expectedSequence ?? sequence
        let off = expectedOffset ?? offset
        let code: UInt8 = error != 0 ? 0x80 : (duplicate ? 1 : (state == 2 ? 3 : (state == 3 ? 4 : 0)))
        let quiet: UInt16 = state == 4 || state == 5 ? (batchActive ? 1_000 : 2_000) : 0
        let capabilities = config.extraCapabilities | (config.batchSupported ? 0x08 : 0) | (batchActive ? 0x10 : 0)
        var payload = Data([request.type, code, state, error])
        payload.testAppend(seq); payload.testAppend(off)
        payload.testAppend(config.voltage); payload.testAppend(UInt16(3_000)); payload.testAppend(quiet)
        payload.append(contentsOf: [0, capabilities])
        var raw = Data([0x4e, 0x43, 1, error != 0 ? 0x81 : 0x80])
        raw.testAppend(request.transferID); raw.testAppend(request.sequence); raw.testAppend(off)
        raw.testAppend(UInt16(16)); raw.testAppend(UInt16(0)); raw.testAppend(NCCRC.crc16(payload))
        let crc = NCCRC.crc16(raw.prefix(12) + raw.suffix(2))
        raw[12] = UInt8(truncatingIfNeeded: crc); raw[13] = UInt8(truncatingIfNeeded: crc >> 8)
        raw.append(payload)
        return try NCAck(data: raw, request: request)
    }
}

private actor FaultMailbox: MailboxTransport {
    let base: TransferMockMailbox
    let command: NCCommand
    let offset: UInt16?
    let afterAcceptance: Bool
    let error: any Error
    let clock: TransferTestClock
    let errorDelay: TimeInterval
    let afterExecuteCount: Int?
    var remaining: Int
    private(set) var attempts: [NCFrame] = []

    init(base: TransferMockMailbox, clock: TransferTestClock, command: NCCommand = .data,
         offset: UInt16? = 2_048, count: Int = 1, afterAcceptance: Bool = true,
         error: any Error = MailboxTransportError.transient("RF response lost"), errorDelay: TimeInterval = 0,
         afterExecuteCount: Int? = nil) {
        self.base = base; self.clock = clock; self.command = command; self.offset = offset
        remaining = count; self.afterAcceptance = afterAcceptance; self.error = error; self.errorDelay = errorDelay
        self.afterExecuteCount = afterExecuteCount
    }

    func exchange(_ frame: NCFrame, timeout: TimeInterval) async throws -> NCAck {
        attempts.append(frame)
        let executed = await base.events.filter { $0.frame.type == NCCommand.execute.rawValue }.count
        if frame.type == command.rawValue, offset == nil || offset == frame.offset, remaining > 0,
           afterExecuteCount == nil || executed >= afterExecuteCount! {
            remaining -= 1
            if afterAcceptance { _ = try await base.exchange(frame, timeout: timeout) }
            await clock.advance(errorDelay)
            throw error
        }
        return try await base.exchange(frame, timeout: timeout)
    }
}

private extension Data {
    mutating func testAppend(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
    }
}

@MainActor
final class TransferCoordinatorTests: XCTestCase {
    private let uid = Data([0xe0, 0x02, 1, 2, 3, 4, 5, 6])
    private var bytes: Data { Data((0..<4_736).map { UInt8(truncatingIfNeeded: $0 * 17) }) }
    private var tested: HardwareProfile {
        // Synthetic measurements for simulation; not a shipping hardware profile.
        try! HardwareProfile(validationReference: "simulated test fixture", normalRefreshSeconds: 8,
                             batchRefreshSeconds: 20, legacyRefreshSeconds: 8)
    }

    func testTransientDataFailureRecoversWithoutStartingANewSession() async throws {
        for afterAcceptance in [false, true] {
            let clock = TransferTestClock()
            let base = TransferMockMailbox(clock: clock)
            let fault = FaultMailbox(base: base, clock: clock, afterAcceptance: afterAcceptance)
            let transport = RetryingDataMailbox(transport: fault, deadline: 60, clock: clock)
            let engine = TransferCoordinator(clock: clock)
            try await engine.prepareImage(bytes, cleanBeforeWrite: false)
            guard case .completed = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested) else {
                return XCTFail("DATA retry did not recover")
            }
            let attempts = await fault.attempts.filter { $0.type == 2 && $0.offset == 2_048 }
            XCTAssertEqual(attempts.count, 2)
            XCTAssertEqual(attempts.first, attempts.last, "Retry must preserve every byte and transfer identity")
            let received = await base.receivedImage()
            let duplicates = await base.duplicates
            XCTAssertEqual(received, bytes)
            XCTAssertEqual(duplicates, afterAcceptance ? 1 : 0)
        }
    }

    func testDamagedDataACKCanBeRetriedButCannotAdvanceByItself() async throws {
        let clock = TransferTestClock()
        let base = TransferMockMailbox(clock: clock)
        let fault = FaultMailbox(base: base, clock: clock, error: NCProtocolError.frame("CRC mismatch"))
        let engine = TransferCoordinator(clock: clock)
        try await engine.prepareImage(bytes, cleanBeforeWrite: false)
        let transport = RetryingDataMailbox(transport: fault, deadline: 60, clock: clock)
        guard case .completed = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested) else { return XCTFail() }
        let attempts = await fault.attempts.filter { $0.type == 2 && $0.offset == 2_048 }
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.first, attempts.last)
    }

    func testDataRetriesAreBoundedAndKeepUnconfirmedPosition() async throws {
        let clock = TransferTestClock()
        let base = TransferMockMailbox(clock: clock)
        let fault = FaultMailbox(base: base, clock: clock, count: 10)
        let engine = TransferCoordinator(clock: clock)
        try await engine.prepareImage(bytes, cleanBeforeWrite: false)
        let transport = RetryingDataMailbox(transport: fault, deadline: 60, clock: clock)
        do { _ = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested); XCTFail() }
        catch is MailboxTransportError {}
        let attempts = await fault.attempts.filter { $0.type == 2 && $0.offset == 2_048 }
        let pending = await engine.pending
        XCTAssertEqual(attempts.count, 3)
        XCTAssertTrue(attempts.allSatisfy { $0 == attempts.first })
        XCTAssertEqual(pending?.expectedOffset, 2_048)
        XCTAssertEqual(pending?.unconfirmedCommand, attempts.last)
        XCTAssertFalse(pending?.executeSent ?? true)
    }

    func testNoDataRetryWithoutSessionTimeOrConnection() async throws {
        for disconnected in [false, true] {
            let clock = TransferTestClock()
            let base = TransferMockMailbox(clock: clock)
            let failure: any Error = disconnected ? MailboxTransportError.connectionLost("NFCError 100") : MailboxTransportError.transient("RF")
            let fault = FaultMailbox(base: base, clock: clock, offset: 0, error: failure, errorDelay: disconnected ? 0 : 2)
            let deadline: TimeInterval = disconnected ? 60 : 5
            let transport = RetryingDataMailbox(transport: fault, deadline: deadline, clock: clock)
            let engine = TransferCoordinator(clock: clock)
            try await engine.prepareImage(bytes, cleanBeforeWrite: false)
            do { _ = try await engine.run(transport: transport, uid: uid, deadline: deadline, policy: tested); XCTFail() }
            catch is MailboxTransportError {}
            let attempts = await fault.attempts.filter { $0.type == 2 }
            XCTAssertEqual(attempts.count, 1)
        }
    }

    func testCommitAndExecuteAreNeverBlindlyRetried() async throws {
        for command: NCCommand in [.commit, .execute] {
            let clock = TransferTestClock()
            let base = TransferMockMailbox(clock: clock)
            let fault = FaultMailbox(base: base, clock: clock, command: command, offset: nil)
            let engine = TransferCoordinator(clock: clock)
            try await engine.prepareImage(bytes, cleanBeforeWrite: false)
            let transport = RetryingDataMailbox(transport: fault, deadline: 60, clock: clock)
            if command == .execute {
                guard case .holdField = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested) else { return XCTFail() }
            } else {
                do { _ = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested); XCTFail() }
                catch is MailboxTransportError {}
            }
            let attempts = await fault.attempts.filter { $0.type == command.rawValue }
            XCTAssertEqual(attempts.count, 1)
        }
    }

    func testMonochromeWireChunksAndQuietWindows() async throws {
        let clock = TransferTestClock()
        let coordinator = TransferCoordinator(clock: clock)
        let transport = TransferMockMailbox(clock: clock)
        try await coordinator.prepareImage(bytes, cleanBeforeWrite: false)
        let result = try await coordinator.run(transport: transport, uid: uid, deadline: 60, policy: tested)
        guard case .completed = result else { return XCTFail("did not complete") }
        let events = await transport.events
        let chunks = events.filter { $0.frame.type == NCCommand.data.rawValue }
        XCTAssertEqual(chunks.count, 37)
        XCTAssertTrue(chunks.allSatisfy { $0.frame.payload.count == 128 })
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1.frame.payload) }, bytes)
        XCTAssertEqual(events.first?.time, 1.5)
        let commit = events.firstIndex { $0.frame.type == 3 }!
        XCTAssertGreaterThanOrEqual(events[commit + 1].time - events[commit].time, 1.5)
        let execute = events.firstIndex { $0.frame.type == 5 }!
        XCTAssertGreaterThanOrEqual(events[execute + 1].time - events[execute].time, 2.25)
        let pending = await coordinator.pending
        XCTAssertNil(pending)
    }

    func testVoltagePacingMatchesAndroid() async throws {
        for (voltage, expectedGap): (UInt16, Double) in [(3_250, 0.05), (3_100, 0.2), (3_000, 0.5)] {
            let clock = TransferTestClock()
            var config = TransferMockMailbox.Configuration(); config.voltage = voltage
            let transport = TransferMockMailbox(clock: clock, configuration: config)
            let engine = TransferCoordinator(clock: clock)
            try await engine.prepareImage(bytes, cleanBeforeWrite: false)
            _ = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested)
            let chunks = await transport.events.filter { $0.frame.type == 2 }
            XCTAssertEqual(chunks[1].time - chunks[0].time, expectedGap + 0.05, accuracy: 0.000_001)
        }
    }

    func testDataSlicesAreNormalizedBeforeTransfer() async throws {
        let clock = TransferTestClock()
        let transport = TransferMockMailbox(clock: clock)
        let engine = TransferCoordinator(clock: clock)
        let padded = Data([99]) + bytes
        let sliced = padded.dropFirst()
        XCTAssertNotEqual(sliced.startIndex, 0)
        try await engine.prepareImage(sliced, cleanBeforeWrite: false)
        guard case .completed = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested) else { return XCTFail() }
        let chunks = await transport.events.filter { $0.frame.type == 2 }
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1.frame.payload) }, bytes)
    }

    func testBatchAndLegacyCleaning() async throws {
        for batchSupported in [true, false] {
            let clock = TransferTestClock()
            var config = TransferMockMailbox.Configuration(); config.batchSupported = batchSupported
            let transport = TransferMockMailbox(clock: clock, configuration: config)
            let engine = TransferCoordinator(clock: clock)
            try await engine.prepareImage(bytes)
            let result = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested)
            guard case .completed = result else { return XCTFail("cleaning not complete") }
            let frames = await transport.events.map(\.frame)
            let patterns = frames.filter { $0.type == 6 }.map { $0.payload[0] }
            XCTAssertEqual(patterns, batchSupported ? [] : [4, 3, 4])
            XCTAssertEqual(frames.filter { $0.type == 5 }.count, 4)
            XCTAssertEqual(frames.first { $0.type == 1 }!.payload[12], batchSupported ? 1 : 0)
        }
    }

    func testShippingProfileAllowsStatusButNoDisplayWrites() async throws {
        let clock = TransferTestClock(), transport = TransferMockMailbox(clock: TransferTestClock())
        let engine = TransferCoordinator(clock: clock)
        try await engine.preparePattern(4)
        do {
            _ = try await engine.run(transport: transport, uid: uid, deadline: 60)
            XCTFail("unvalidated display write allowed")
        } catch { XCTAssertEqual(error as? TransferError, .unvalidatedHardware) }
        let frames = await transport.events.map(\.frame)
        XCTAssertEqual(frames.map(\.type), [4])
        try await engine.prepareStatus()
        guard case .completed = try await engine.run(transport: transport, uid: uid, deadline: 60) else {
            return XCTFail("status blocked")
        }
    }

    func testBetaProfileAllowsMonochromeButStillDefersLateExecuteAndRejectsGrayTransitions() async throws {
        XCTAssertNil(HardwareProfile.betaTesting.validationReference)
        XCTAssertTrue(HardwareProfile.betaTesting.isBetaTesting)
        XCTAssertFalse(HardwareProfile.betaTesting.isDeveloperTesting)
        for capability: UInt8 in [0, 0x40, 0x80] {
            let clock = TransferTestClock()
            var config = TransferMockMailbox.Configuration()
            config.extraCapabilities = capability
            let transport = TransferMockMailbox(clock: clock, configuration: config)
            let engine = TransferCoordinator(clock: clock)
            try await engine.preparePattern(4)
            do {
                let result = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: .betaTesting)
                guard capability == 0, case .completed = result else { return XCTFail("gray transition accepted") }
            } catch {
                XCTAssertNotEqual(capability, 0)
                guard case .unvalidatedRoute = error as? TransferError else { return XCTFail("\(error)") }
            }
        }
        let clock = TransferTestClock()
        let transport = TransferMockMailbox(clock: clock)
        let engine = TransferCoordinator(clock: clock)
        try await engine.preparePattern(4)
        guard case .resumeNeeded = try await engine.run(transport: transport, uid: uid, deadline: 14, policy: .betaTesting) else {
            return XCTFail("beta must reserve refresh time plus five seconds")
        }
        let frames = await transport.events.map(\.frame)
        XCTAssertFalse(frames.contains { $0.type == 5 })
    }

    func testGrayWritesAndUnvalidatedGrayTransitionsRefused() async throws {
        let engine = TransferCoordinator()
        do { try await engine.prepareImage(Data(repeating: 0, count: 9_472)); XCTFail("gray accepted") }
        catch { XCTAssertEqual(error as? TransferError, .grayWriteUnavailable) }
        for capability: UInt8 in [0x40, 0x80] {
            let clock = TransferTestClock()
            var config = TransferMockMailbox.Configuration(); config.extraCapabilities = capability
            let transport = TransferMockMailbox(clock: clock, configuration: config)
            let coordinator = TransferCoordinator(clock: clock)
            try await coordinator.preparePattern(1)
            do { _ = try await coordinator.run(transport: transport, uid: uid, deadline: 60, policy: tested); XCTFail("gray transition accepted") }
            catch { guard case .unvalidatedRoute = error as? TransferError else { return XCTFail("wrong error \(error)") } }
            let events = await transport.events
            XCTAssertEqual(events.count, 1)
        }
    }

    func testDeadlineDefersExecuteAndBindsUID() async throws {
        let clock = TransferTestClock()
        let coordinator = TransferCoordinator(clock: clock)
        let transport = TransferMockMailbox(clock: clock)
        try await coordinator.preparePattern(4)
        guard case .resumeNeeded = try await coordinator.run(transport: transport, uid: uid, deadline: 10, policy: tested) else {
            return XCTFail("must defer execute")
        }
        let before = await transport.events
        XCTAssertFalse(before.contains { $0.frame.type == 5 })
        do { _ = try await coordinator.run(transport: transport, uid: Data([8]), deadline: 80, policy: tested); XCTFail("wrong UID accepted") }
        catch { XCTAssertEqual(error as? TransferError, .differentTag) }
        let afterWrongTag = await transport.events
        XCTAssertEqual(before.count, afterWrongTag.count)
        guard case .completed = try await coordinator.run(transport: transport, uid: uid, deadline: 80, policy: tested) else {
            return XCTFail("same UID did not resume")
        }
    }

    func testLostDataACKResendsExactCommandAndAcceptsDuplicate() async throws {
        let clock = TransferTestClock()
        var config = TransferMockMailbox.Configuration(); config.dropDataOffset = 256
        let transport = TransferMockMailbox(clock: clock, configuration: config)
        let engine = TransferCoordinator(clock: clock)
        try await engine.prepareImage(bytes, cleanBeforeWrite: false)
        do { _ = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested); XCTFail("loss not surfaced") }
        catch { XCTAssertTrue(error is MockLinkError) }
        let pending = await engine.pending
        XCTAssertEqual(pending?.expectedOffset, 256)
        XCTAssertEqual(pending?.unconfirmedCommand?.offset, 256)
        guard case .completed = try await engine.run(transport: transport, uid: uid, deadline: 80, policy: tested) else {
            return XCTFail("resume failed")
        }
        let duplicates = await transport.duplicates
        XCTAssertEqual(duplicates, 1)
    }

    func testFourRediscoveriesResumeSameImageWithAndWithoutRAMLoss() async throws {
        for losesRAM in [false, true] {
            let clock = TransferTestClock()
            let base = TransferMockMailbox(clock: clock)
            let fault = FaultMailbox(base: base, clock: clock, count: 4,
                                     error: MailboxTransportError.connectionLost("tag lost"))
            let engine = TransferCoordinator(clock: clock)
            var recovery = TransferRediscovery()
            try await engine.prepareImage(bytes, cleanBeforeWrite: false)
            for _ in 0..<4 {
                do {
                    _ = try await engine.run(transport: fault, uid: uid, deadline: 60, policy: tested)
                    XCTFail("Expected disconnect")
                } catch {
                    guard case MailboxTransportError.connectionLost = error else { return XCTFail("\(error)") }
                }
                let snapshot = await engine.pending
                let now = await clock.now()
                XCTAssertTrue(recovery.reserve(snapshot: snapshot, now: now, deadline: 60))
                if losesRAM { await base.simulateLossOfRAMBeforeExecute() }
            }
            XCTAssertEqual(recovery.attempts, 4)
            guard case .completed = try await engine.run(transport: fault, uid: uid, deadline: 60, policy: tested) else {
                return XCTFail("Did not finish within original deadline")
            }
            let received = await base.receivedImage()
            XCTAssertEqual(received, bytes)
            let executes = await base.events.filter { $0.frame.type == NCCommand.execute.rawValue }
            XCTAssertEqual(executes.count, 1)
        }
    }

    func testRAMLossWhileExecuteWasDeferredRestartsWithCleaning() async throws {
        let clock = TransferTestClock()
        let transport = TransferMockMailbox(clock: clock)
        let engine = TransferCoordinator(clock: clock)
        try await engine.prepareImage(bytes, cleanBeforeWrite: false)
        guard case .resumeNeeded = try await engine.run(transport: transport, uid: uid, deadline: 15, policy: tested) else { return XCTFail() }
        await transport.simulateLossOfRAMBeforeExecute()
        guard case .completed = try await engine.run(transport: transport, uid: uid, deadline: 80, policy: tested) else { return XCTFail() }
        let starts = await transport.events.filter { $0.frame.type == 1 }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[1].frame.payload[12], 1)
    }

    func testOlderPendingFlashAfterCommitACKReplaysTargetWithCleaning() async throws {
        for (oldSequence, oldOffset): (UInt16, UInt16) in [(17, 4_736), (39, 4_608)] {
            let clock = TransferTestClock()
            let transport = TransferMockMailbox(clock: clock)
            let engine = TransferCoordinator(clock: clock)
            try await engine.prepareImage(bytes, cleanBeforeWrite: false)
            guard case .resumeNeeded = try await engine.run(transport: transport, uid: uid, deadline: 15, policy: tested) else { return XCTFail() }
            let paused = await engine.pending
            XCTAssertEqual(paused?.expectedSequence, 39)
            XCTAssertEqual(paused?.expectedOffset, 4_736)
            // COMMIT was ACKed, but a reboot restored an older pending record
            // before the new target's Flash stage was committed.
            await transport.simulateRestoredOlderPending(sequence: oldSequence, offset: oldOffset,
                                                        reportChargingOnce: oldSequence == 17)
            guard case .completed = try await engine.run(transport: transport, uid: uid, deadline: 100, policy: tested) else { return XCTFail() }
            let frames = await transport.events.map(\.frame)
            let starts = frames.filter { $0.type == 1 }
            XCTAssertEqual(starts.count, 2)
            XCTAssertNotEqual(starts[0].transferID, starts[1].transferID)
            XCTAssertEqual(starts[1].payload[12], 1)
            let replayed = frames.filter { $0.type == 2 && $0.transferID == starts[1].transferID }
            XCTAssertEqual(replayed.reduce(into: Data()) { $0.append($1.payload) }, bytes)
            XCTAssertTrue(frames.filter { $0.type == 5 }.allSatisfy { $0.transferID == starts[1].transferID })
        }
    }

    func testLostCommitACKThenRestoredPendingReplaysImageInsteadOfRejectingEveryScan() async throws {
        for rebooted in [false, true] {
            let clock = TransferTestClock()
            let base = TransferMockMailbox(clock: clock)
            let fault = FaultMailbox(base: base, clock: clock, command: .commit, offset: nil,
                                     error: MailboxTransportError.connectionLost("isAvailable=false"))
            let engine = TransferCoordinator(clock: clock)
            try await engine.prepareImage(bytes, cleanBeforeWrite: false)
            do {
                _ = try await engine.run(transport: fault, uid: uid, deadline: 60, policy: tested)
                XCTFail("Expected lost COMMIT ACK")
            } catch { XCTAssertTrue(error is MailboxTransportError) }
            let before = await engine.pending
            XCTAssertEqual(before?.unconfirmedCommand?.type, NCCommand.commit.rawValue)
            XCTAssertEqual(before?.expectedSequence, 38)
            if rebooted { await base.restorePendingWithoutDuplicateCache() }
            guard case .completed = try await engine.run(transport: base, uid: uid, deadline: 100, policy: tested) else {
                return XCTFail("Saved image did not recover")
            }
            let frames = await base.events.map(\.frame)
            let starts = frames.filter { $0.type == NCCommand.start.rawValue }
            XCTAssertEqual(starts.count, 2)
            XCTAssertNotEqual(starts.first?.transferID, starts.last?.transferID)
            let executed = frames.filter { $0.type == NCCommand.execute.rawValue }
            XCTAssertEqual(executed.count, 4) // The replacement is cleaned before display.
            XCTAssertTrue(executed.allSatisfy { $0.transferID == starts.last?.transferID })
            let received = await base.receivedImage()
            XCTAssertEqual(received, bytes)
        }
    }

    func testMCURestartRestartsImageAndSequenceRewindResendsKnownData() async throws {
        for restart in [true, false] {
            let clock = TransferTestClock()
            var config = TransferMockMailbox.Configuration()
            if restart { config.rejectTransferOffset = 256 } else { config.rewindAtOffset = 256 }
            let transport = TransferMockMailbox(clock: clock, configuration: config)
            let engine = TransferCoordinator(clock: clock)
            try await engine.prepareImage(bytes, cleanBeforeWrite: false)
            guard case .completed = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested) else {
                return XCTFail("recovery failed")
            }
            let frames = await transport.events.map(\.frame)
            XCTAssertEqual(frames.filter { $0.type == 1 }.count, restart ? 2 : 1)
            XCTAssertEqual(frames.filter { $0.type == 2 && $0.offset == 128 }.count, 2)
        }
    }

    func testInvalidForwardPositionAndStaleACKNeverSkipData() async throws {
        for stale in [true, false] {
            let clock = TransferTestClock()
            var config = TransferMockMailbox.Configuration()
            if stale { config.staleAtOffset = 256 } else { config.forwardAtOffset = 256 }
            let transport = TransferMockMailbox(clock: clock, configuration: config)
            let engine = TransferCoordinator(clock: clock)
            try await engine.prepareImage(bytes, cleanBeforeWrite: false)
            do { _ = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested); XCTFail("bad ACK accepted") }
            catch { XCTAssertEqual(error as? TransferError, .inconsistentAcknowledgement) }
            let frames = await transport.events.map(\.frame)
            XCTAssertFalse(frames.contains { $0.type == 3 || $0.type == 5 })
            let paused = await engine.pending
            XCTAssertEqual(paused?.uid, uid)
            XCTAssertNil(paused?.transferID, "Invalid position must not survive to poison the next rescan")
            guard case .completed = try await engine.run(transport: transport, uid: uid, deadline: 100, policy: tested) else {
                return XCTFail("Rescan is stuck on the same invalid position")
            }
            let allFrames = await transport.events.map(\.frame)
            let starts = allFrames.filter { $0.type == 1 }
            XCTAssertEqual(starts.count, 2)
            XCTAssertNotEqual(starts.first?.transferID, starts.last?.transferID)
            let received = await transport.receivedImage()
            XCTAssertEqual(received, bytes)
        }
    }

    func testOldCompleteDoesNotCompleteNewTarget() async throws {
        let clock = TransferTestClock()
        var config = TransferMockMailbox.Configuration(); config.initialState = 6
        let transport = TransferMockMailbox(clock: clock, configuration: config)
        let engine = TransferCoordinator(clock: clock)
        try await engine.prepareImage(bytes, cleanBeforeWrite: false)
        guard case .completed = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested) else { return XCTFail() }
        let frames = await transport.events.map(\.frame)
        XCTAssertEqual(frames.filter { $0.type == 2 }.count, 37)
        XCTAssertEqual(frames.filter { $0.type == 5 }.count, 1)
    }

    func testLostExecuteACKHoldsFieldThenReplaysTargetWithCleaning() async throws {
        let clock = TransferTestClock()
        var config = TransferMockMailbox.Configuration(); config.loseExecuteNumber = 1
        let transport = TransferMockMailbox(clock: clock, configuration: config)
        let engine = TransferCoordinator(clock: clock)
        try await engine.prepareImage(bytes, cleanBeforeWrite: false)
        guard case .holdField = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested) else {
            return XCTFail("must keep field after unconfirmed execute")
        }
        let pending = await engine.pending
        XCTAssertEqual(pending?.executeSent, true)
        XCTAssertEqual(pending?.executeAcknowledged, false)
        XCTAssertEqual(pending?.unconfirmedCommand?.type, 5)
        guard case .completed = try await engine.run(transport: transport, uid: uid, deadline: 100, policy: tested) else {
            return XCTFail("replay failed")
        }
        let starts = await transport.events.filter { $0.frame.type == 1 }
        XCTAssertEqual(starts.count, 2)
        XCTAssertNotEqual(starts[0].frame.transferID, starts[1].frame.transferID)
        XCTAssertEqual(starts[1].frame.payload[12], 1)
    }

    func testCompletionWithWrongExpectedSequenceIsRejected() async throws {
        let clock = TransferTestClock()
        var config = TransferMockMailbox.Configuration(); config.wrongCompletePosition = true
        let transport = TransferMockMailbox(clock: clock, configuration: config)
        let engine = TransferCoordinator(clock: clock)
        try await engine.preparePattern(4)
        do { _ = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested); XCTFail("unrelated completion accepted") }
        catch { XCTAssertEqual(error as? TransferError, .inconsistentAcknowledgement) }
        let pending = await engine.pending
        XCTAssertNotNil(pending)
    }

    func testSecondConsecutiveImageCompletesAfterLostStatusWithoutRepeatingExecute() async throws {
        for clean in [false, true] {
            let clock = TransferTestClock()
            let base = TransferMockMailbox(clock: clock)
            let engine = TransferCoordinator(clock: clock)
            try await engine.prepareImage(bytes, cleanBeforeWrite: clean)
            guard case .completed = try await engine.run(transport: base, uid: uid, deadline: 60, policy: tested) else { return XCTFail() }
            let firstExecutes = await base.events.filter { $0.frame.type == NCCommand.execute.rawValue }.count
            let fault = FaultMailbox(base: base, clock: clock, command: .status, offset: nil,
                                     count: clean ? 2 : 1, afterExecuteCount: firstExecutes + 1)
            let nextImage = Data(bytes.map { ~$0 })
            try await engine.prepareImage(nextImage, cleanBeforeWrite: clean)
            let deadline = await clock.now() + 60
            guard case .completed = try await engine.run(transport: fault, uid: uid, deadline: deadline, policy: tested) else {
                return XCTFail("Display completed, but the final confirmation was abandoned")
            }
            let frames = await base.events.map(\.frame)
            XCTAssertEqual(frames.filter { $0.type == NCCommand.start.rawValue }.count, 2)
            XCTAssertEqual(frames.filter { $0.type == NCCommand.execute.rawValue }.count, 2 * firstExecutes)
            let events = await base.events
            let firstConfirmation = try XCTUnwrap(events.lastIndex { $0.frame.type == NCCommand.start.rawValue })
            let currentEvents = Array(events.dropFirst(firstConfirmation))
            let executedAt = try XCTUnwrap(currentEvents.firstIndex { $0.frame.type == NCCommand.execute.rawValue })
            let confirmations = Array(currentEvents.dropFirst(executedAt + 1).prefix { $0.frame.type == NCCommand.status.rawValue })
            XCTAssertGreaterThanOrEqual(confirmations.count, clean ? 3 : 2)
            let firstRead = try XCTUnwrap(confirmations.first)
            let retryRead = try XCTUnwrap(confirmations.dropFirst().first)
            XCTAssertGreaterThanOrEqual(retryRead.time - firstRead.time, clean ? 1.25 : 2.25)
            let received = await base.receivedImage()
            XCTAssertEqual(received, nextImage)
            let pending = await engine.pending
            XCTAssertNil(pending)
        }
    }

    func testCompletionReadRetriesStayFiniteAndNeverRestartTheFieldOrExecute() async throws {
        for error in [MailboxTransportError.transient("ACK timeout"), .connectionLost("isAvailable=false")] {
            let clock = TransferTestClock()
            let base = TransferMockMailbox(clock: clock)
            let fault = FaultMailbox(base: base, clock: clock, command: .status, offset: nil, count: 10,
                                     error: error, afterExecuteCount: 1)
            let engine = TransferCoordinator(clock: clock)
            try await engine.prepareImage(bytes, cleanBeforeWrite: false)
            let policy = try HardwareProfile(validationReference: "simulated", normalRefreshSeconds: 20)
            guard case .holdField = try await engine.run(transport: fault, uid: uid, deadline: 60, policy: policy) else {
                return XCTFail("Unconfirmed update must not become a success")
            }
            let frames = await fault.attempts
            let executeIndex = try XCTUnwrap(frames.firstIndex { $0.type == NCCommand.execute.rawValue })
            let confirmation = frames.dropFirst(executeIndex + 1)
            let expectedAttempts: Int
            if case .transient = error { expectedAttempts = 3 } else { expectedAttempts = 1 }
            XCTAssertEqual(confirmation.count, expectedAttempts)
            XCTAssertTrue(confirmation.allSatisfy { $0.type == NCCommand.status.rawValue })
            XCTAssertEqual(Set(confirmation.map(\.sequence)).count, 1)
            let pending = await engine.pending
            XCTAssertEqual(pending?.executeAcknowledged, true)
            XCTAssertEqual(pending?.refreshMayBeActive, true)
        }
    }

    func testCompletionRetryDoesNotExceedRefreshBudget() async throws {
        let clock = TransferTestClock()
        let base = TransferMockMailbox(clock: clock)
        let fault = FaultMailbox(base: base, clock: clock, command: .status, offset: nil, afterExecuteCount: 1)
        let engine = TransferCoordinator(clock: clock)
        try await engine.prepareImage(bytes, cleanBeforeWrite: false)
        let shortProfile = try HardwareProfile(validationReference: "simulated", normalRefreshSeconds: 3)
        guard case .holdField = try await engine.run(transport: fault, uid: uid, deadline: 60, policy: shortProfile) else { return XCTFail() }
        let frames = await fault.attempts
        let executeIndex = try XCTUnwrap(frames.firstIndex { $0.type == NCCommand.execute.rawValue })
        XCTAssertEqual(frames.dropFirst(executeIndex + 1).count, 1)
    }

    func testDamagedCompletionACKRequiresFreshValidatedStatus() async throws {
        let clock = TransferTestClock()
        let base = TransferMockMailbox(clock: clock)
        let fault = FaultMailbox(base: base, clock: clock, command: .status, offset: nil,
                                 error: NCProtocolError.frame("CRC mismatch"), afterExecuteCount: 1)
        let engine = TransferCoordinator(clock: clock)
        try await engine.prepareImage(bytes, cleanBeforeWrite: false)
        guard case .completed = try await engine.run(transport: fault, uid: uid, deadline: 60, policy: tested) else { return XCTFail() }
        let frames = await fault.attempts
        XCTAssertEqual(frames.filter { $0.type == NCCommand.execute.rawValue }.count, 1)
        let executeIndex = try XCTUnwrap(frames.firstIndex { $0.type == NCCommand.execute.rawValue })
        XCTAssertEqual(frames.dropFirst(executeIndex + 1).count, 2)
    }

    func testChargingAndExecuteDeferralsAreFinite() async throws {
        for neverReady in [true, false] {
            let clock = TransferTestClock()
            var config = TransferMockMailbox.Configuration()
            config.chargeNeverReady = neverReady
            config.deferExecuteCount = neverReady ? 0 : 100
            let transport = TransferMockMailbox(clock: clock, configuration: config)
            let engine = TransferCoordinator(clock: clock)
            try await engine.preparePattern(4)
            do { _ = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested); XCTFail("charging must time out") }
            catch { XCTAssertEqual(error as? TransferError, .chargingTimeout) }
            let frames = await transport.events.map(\.frame)
            XCTAssertLessThan(frames.count, 35)
            if neverReady { XCTAssertFalse(frames.contains { $0.type == 5 }) }
        }
    }

    func testUnfinishedRefreshHoldsFieldInsteadOfInvalidatingSession() async throws {
        let clock = TransferTestClock()
        var config = TransferMockMailbox.Configuration(); config.refreshNeverCompletes = true
        let transport = TransferMockMailbox(clock: clock, configuration: config)
        let engine = TransferCoordinator(clock: clock)
        try await engine.preparePattern(4)
        guard case .holdField = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested) else {
            return XCTFail("refresh must retain RF")
        }
        let pending = await engine.pending
        XCTAssertEqual(pending?.refreshMayBeActive, true)
        let frames = await transport.events.map(\.frame)
        XCTAssertEqual(frames.filter { $0.type == 5 }.count, 1)
    }

    func testSequenceOnlyAdvancesConfirmedPatternsAcrossSessions() async throws {
        let clock = TransferTestClock()
        var config = TransferMockMailbox.Configuration(); config.loseExecuteNumber = 3
        let transport = TransferMockMailbox(clock: clock, configuration: config)
        let engine = TransferCoordinator(clock: clock)
        try await engine.prepareSequence()
        guard case .holdField = try await engine.run(transport: transport, uid: uid, deadline: 60, policy: tested) else { return XCTFail() }
        let pending = await engine.pending
        XCTAssertEqual(pending?.nextPattern, 3)
        guard case .completed = try await engine.run(transport: transport, uid: uid, deadline: 100, policy: tested) else { return XCTFail() }
        let patterns = await transport.events.filter { $0.frame.type == 6 }.map { $0.frame.payload[0] }
        XCTAssertEqual(patterns, [1, 2, 3, 3, 4, 5, 6, 7, 8, 9, 10])
    }
}
