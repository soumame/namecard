import Foundation

/// Owns one UID-bound job. No successful STATUS alone proves the target image:
/// STATUS echoes the request's transfer ID, not the firmware's active ID.
public actor TransferCoordinator {
    private enum WorkContent { case image(Data), pattern(UInt8) }
    private final class Work {
        let content: WorkContent
        let id: UInt16
        let route: TransferRoute
        let batch: Bool
        var started = false
        var committed = false
        var sequence: UInt16 = 0
        var offset: UInt16 = 0
        var highestSentOffset: UInt16 = 0
        var lastAck: NCAck?
        var unconfirmed: NCFrame?
        var executeSent = false
        var executeAcknowledged = false
        var refreshMayBeActive = false
        init(content: WorkContent, id: UInt16, route: TransferRoute, batch: Bool) {
            self.content = content; self.id = id; self.route = route; self.batch = batch
        }
    }
    private final class Job {
        let kind: TransferJob
        var uid: Data?
        var work: Work?
        var lastAck: NCAck?
        var cleanRequired = false
        var cleanStep = 0
        var nextPattern = 1
        var needsReconnectRecovery = false
        init(_ kind: TransferJob) {
            self.kind = kind
            if case .image(_, let clean) = kind { cleanRequired = clean }
        }
    }
    private struct NeedResume: Error { let message: String }
    private struct HoldField: Error { let message: String }
    private let clock: any TransferClock
    private var nextID: UInt16
    private var job: Job?
    private var running = false
    private let cleanPatterns: [UInt8] = [4, 3, 4]
    private let imageBytes = 4_736

    public init(clock: any TransferClock = SystemTransferClock(),
                initialTransferID: UInt16 = UInt16.random(in: 1...UInt16.max)) {
        self.clock = clock; nextID = initialTransferID
    }

    public var pending: TransferSnapshot? {
        guard let job else { return nil }
        let work = job.work
        return TransferSnapshot(job: job.kind, uid: job.uid, transferID: work?.id,
                                expectedSequence: work?.sequence ?? 0,
                                expectedOffset: work?.offset ?? 0,
                                lastAck: work?.lastAck ?? job.lastAck,
                                unconfirmedCommand: work?.unconfirmed,
                                executeSent: work?.executeSent ?? false,
                                executeAcknowledged: work?.executeAcknowledged ?? false,
                                refreshMayBeActive: work?.refreshMayBeActive ?? false,
                                nextPattern: job.nextPattern)
    }

    public func prepareImage(_ bytes: Data, cleanBeforeWrite: Bool = true) throws {
        guard !running else { throw TransferError.busy }
        if bytes.count == 9_472 { throw TransferError.grayWriteUnavailable }
        guard bytes.count == imageBytes else { throw TransferError.invalidImage }
        job = Job(.image(Data([UInt8](bytes)), cleanBeforeWrite: cleanBeforeWrite))
    }
    public func preparePattern(_ id: UInt8) throws {
        guard !running else { throw TransferError.busy }
        guard (1...10).contains(id) else { throw TransferError.invalidPattern }
        job = Job(.pattern(id))
    }
    public func prepareSequence() throws {
        guard !running else { throw TransferError.busy }; job = Job(.sequence)
    }
    public func prepareStatus() throws {
        guard !running else { throw TransferError.busy }; job = Job(.status)
    }
    public func clearPending() throws {
        guard !running else { throw TransferError.busy }; job = nil
    }

    public func run(transport: any MailboxTransport, uid: Data, deadline: TimeInterval,
                    policy: HardwareProfile = .unvalidated,
                    onProgress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws -> TransferOutcome {
        guard !running else { throw TransferError.busy }
        guard let job else { throw TransferError.noPendingJob }
        if let bound = job.uid, bound != uid { throw TransferError.differentTag }
        job.uid = uid
        running = true
        defer { running = false; job.needsReconnectRecovery = true }
        do {
            emit(.starting, "MCU起動のため1.5秒待ちます。名刺とiPhoneを固定してください。", onProgress)
            try await safePause(1.5, deadline: deadline)
            let status = try await transport.exchange(NCFrame(command: .status, transferID: job.work?.id ?? allocateID()), timeout: 1.5)
            job.lastAck = status
            emit(.diagnostic, "STATUS: state=\(status.state) VDD=\(status.vddMV)mV min=\(status.minimumVddMV)mV error=\(status.error)", onProgress)
            if case .status = job.kind { self.job = nil; return .completed(status) }

            // A different reader may have started an update. Preserve the field
            // even when our own display-write profile is disabled.
            if status.state == 4 || status.state == 5 {
                throw HoldField(message: "名刺側の更新中です。端末を固定し、NFCセッション終了後に同じ名刺で再開してください。")
            }

            let grayTransition = status.currentDisplayIsGray || status.hasGrayPlane0Pending
            if grayTransition { _ = try policy.duration(for: .grayTransition) }
            _ = try policy.duration(for: .normal)
            // A rescan cannot prove that an EXECUTE completed or which image a
            // restored COMPLETE refers to. Repeat the target, adding cleaning.
            if job.needsReconnectRecovery, let work = job.work, work.executeSent {
                job.work = nil
                if case .image = job.kind { job.cleanRequired = true; job.cleanStep = 0 }
            }
            if status.state == 7 || (status.hasPendingImage && job.work == nil) {
                if case .image = job.kind { job.cleanRequired = true; job.cleanStep = 0 }
            }
            // An idle/complete MCU has lost an incomplete RAM transfer. Never
            // promote that old COMPLETE into success for this new target.
            if let work = job.work, !work.executeSent, status.state == 0 || status.state == 6 {
                job.work = nil
            }
            if let work = job.work,
               (status.state == 1 && work.committed) || status.state == 7 ||
                (!work.committed && (status.state == 2 || status.state == 3)) ||
                (work.committed && (status.state == 2 || status.state == 3) &&
                 (status.expectedSequence != work.sequence || status.expectedOffset != work.offset)) ||
                (grayTransition && work.route != .grayTransition) {
                // A lost COMMIT ACK leaves local committed=false while the
                // MCU can restore CHARGING/READY without its duplicate cache.
                // STATUS cannot prove the target identity; start a fresh upload.
                // COMMIT can also be ACKed before staging replaces the previous
                // pending Flash record. If power fails in that window, READY
                // may describe an older target: replay ours instead of getting
                // stuck rejecting the same restored position on every scan.
                job.work = nil
                if case .image = job.kind { job.cleanRequired = true; job.cleanStep = 0 }
            }
            switch job.kind {
            case .image(let bytes, _):
                let batch = job.cleanRequired && status.supportsBatchClean
                if job.cleanRequired && !batch {
                    _ = try policy.duration(for: .legacy)
                    while job.cleanStep < cleanPatterns.count {
                        let pattern = cleanPatterns[job.cleanStep]
                        emit(.cleaning, "画面クリーニング \(job.cleanStep + 1)/3", onProgress, pattern: Int(pattern))
                        let route: TransferRoute = grayTransition && job.cleanStep == 0 ? .grayTransition : .legacy
                        let work = job.work ?? makeWork(.pattern(pattern), route: route, batch: false)
                        job.work = work
                        _ = try await perform(work, transport: transport, deadline: deadline, policy: policy, onProgress: onProgress)
                        job.cleanStep += 1
                        job.work = nil
                    }
                }
                let route: TransferRoute = grayTransition && (batch || !job.cleanRequired) ? .grayTransition : (batch ? .batch : .normal)
                let work = job.work ?? makeWork(.image(bytes), route: route, batch: batch)
                job.work = work
                let result = try await perform(work, transport: transport, deadline: deadline, policy: policy, onProgress: onProgress)
                self.job = nil
                emit(.completed, "画像の書き込みが完了しました。", onProgress, completed: imageBytes)
                return .completed(result)
            case .pattern(let id):
                let work = job.work ?? makeWork(.pattern(id), route: grayTransition ? .grayTransition : .normal, batch: false)
                job.work = work
                let result = try await perform(work, transport: transport, deadline: deadline, policy: policy, onProgress: onProgress)
                self.job = nil
                emit(.completed, "パターン\(id)の更新が完了しました。", onProgress, pattern: Int(id))
                return .completed(result)
            case .sequence:
                var result = status
                while job.nextPattern <= 10 {
                    let id = UInt8(job.nextPattern)
                    emit(.sending, "連続試験 \(id)/10", onProgress, pattern: Int(id))
                    let route: TransferRoute = grayTransition && id == 1 ? .grayTransition : .normal
                    let work = job.work ?? makeWork(.pattern(id), route: route, batch: false)
                    job.work = work
                    result = try await perform(work, transport: transport, deadline: deadline, policy: policy, onProgress: onProgress)
                    job.nextPattern += 1 // Only a confirmed COMPLETE advances the sequence.
                    job.work = nil
                }
                self.job = nil
                emit(.completed, "10パターンの連続試験が完了しました。", onProgress)
                return .completed(result)
            case .status: preconditionFailure("handled above")
            }
        } catch let error as NeedResume {
            emit(.resumeRequired, error.message, onProgress)
            return .resumeNeeded(error.message)
        } catch let error as HoldField {
            emit(.resumeRequired, error.message, onProgress)
            return .holdField(error.message)
        } catch {
            if job.work?.refreshMayBeActive == true {
                let message = "表示は更新済みの可能性がありますが、完了応答を確認できません（\(error.localizedDescription)）。端末を固定し、NFCセッション終了後に同じ名刺で再開してください。"
                emit(.resumeRequired, message, onProgress)
                return .holdField(message)
            }
            if job.work?.executeSent == false,
               error as? TransferError == .inconsistentAcknowledgement ||
                error as? TransferError == .firmwareRestarted {
                // Reject the response, but do not retain a position that will
                // reject forever on every user rescan. Keep the UID and image.
                job.work = nil
                if case .image = job.kind { job.cleanRequired = true; job.cleanStep = 0 }
            }
            throw error
        }
    }

    private func allocateID() -> UInt16 { defer { nextID = nextID &+ 1 }; return nextID }
    private func makeWork(_ content: WorkContent, route: TransferRoute, batch: Bool) -> Work {
        Work(content: content, id: allocateID(), route: route, batch: batch)
    }
    private func emit(_ phase: TransferProgress.Phase, _ message: String,
                      _ callback: @Sendable (TransferProgress) -> Void, completed: Int = 0, pattern: Int? = nil) {
        callback(TransferProgress(phase: phase, message: message, completedBytes: completed,
                                  totalBytes: imageBytes, pattern: pattern))
    }
    private func safePause(_ seconds: TimeInterval, deadline: TimeInterval) async throws {
        guard await clock.now() + seconds + 1.5 < deadline else {
            throw NeedResume(message: "NFCセッションの残り時間が不足しています。同じ名刺を再スキャンして続けてください。")
        }
        try await clock.sleep(seconds: seconds)
    }
    private func ensureExchangeTime(_ deadline: TimeInterval) async throws {
        guard await clock.now() + 1.5 < deadline else {
            throw NeedResume(message: "データを保持しました。同じ名刺を再スキャンして続けてください。")
        }
    }
    private func exchange(_ command: NCCommand, work: Work, transport: any MailboxTransport,
                          payload: Data = Data(), timeout: TimeInterval = 1.5) async throws -> NCAck {
        let frame = NCFrame(command: command, transferID: work.id, sequence: work.sequence,
                            offset: work.offset, payload: payload)
        work.unconfirmed = frame
        let ack = try await transport.exchange(frame, timeout: timeout)
        guard ack.acknowledgedType == command.rawValue, ack.transferID == work.id,
              ack.requestSequence == work.sequence else { throw TransferError.inconsistentAcknowledgement }
        work.lastAck = ack
        work.unconfirmed = nil
        return ack
    }
    private func pacing(_ voltage: UInt16) -> TimeInterval {
        voltage >= 3_200 ? 0.05 : (voltage >= 3_050 ? 0.2 : 0.5)
    }

    private func perform(_ work: Work, transport: any MailboxTransport, deadline: TimeInterval,
                         policy: HardwareProfile,
                         onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> NCAck {
        let upperBound = try policy.duration(for: work.route)
        var recoveryCount = 0
        while !work.committed {
            try await ensureExchangeTime(deadline)
            let command: NCCommand
            let payload: Data
            if !work.started {
                work.sequence = 0; work.offset = 0
                switch work.content {
                case .image(let bytes): command = .start; payload = try NCMetadata.image(bytes, batchClean: work.batch)
                case .pattern(let id): command = .pattern; payload = Data([id])
                }
            } else if case .image(let bytes) = work.content, Int(work.offset) < imageBytes {
                command = .data
                let end = min(Int(work.offset) + 128, imageBytes)
                payload = bytes.subdata(in: Int(work.offset)..<end)
                work.highestSentOffset = max(work.highestSentOffset, UInt16(end))
            } else { command = .commit; payload = Data() }
            let ack = try await exchange(command, work: work, transport: transport, payload: payload)
            if ack.error == 7 {
                recoveryCount += 1
                guard recoveryCount <= 2 else { throw TransferError.recoveryLimit }
                work.started = false; work.committed = false; work.highestSentOffset = 0
                continue
            }
            if ack.error == 8 || ack.error == 9 {
                recoveryCount += 1
                let offset = Int(ack.expectedOffset)
                // Only offsets actually sent by this job may be adopted. A
                // STATUS or malformed expected position must never skip data.
                guard recoveryCount <= 3, ack.state == 1,
                      offset <= Int(work.highestSentOffset), offset % 128 == 0,
                      ack.expectedSequence == UInt16(1 + offset / 128) else {
                    throw TransferError.inconsistentAcknowledgement
                }
                work.sequence = ack.expectedSequence; work.offset = ack.expectedOffset
                continue
            }
            try ack.requireSuccess()
            work.started = true
            work.sequence = ack.expectedSequence; work.offset = ack.expectedOffset
            if command == .commit || command == .pattern { work.committed = true }
            emit(.sending, "\(work.offset) / \(imageBytes) bytes（VDD \(ack.vddMV)mV）", onProgress, completed: Int(work.offset))
            if !work.committed { try await safePause(pacing(ack.vddMV), deadline: deadline) }
        }
        emit(.charging, "表示更新のため充電しています。端末を固定してください。", onProgress, completed: imageBytes)
        try await safePause(1.5, deadline: deadline)
        var ready = try await waitReady(work, transport: transport, deadline: deadline, onProgress: onProgress)
        guard await clock.now() + upperBound + 5 < deadline else {
            throw NeedResume(message: "表示更新に必要な時間が不足しています。画像を保持しました。同じ名刺を再スキャンしてください。")
        }
        var refreshLimit: TimeInterval?
        var executionCount = 0
        var executionDeferrals = 0
        while true {
            if ready.state == 3 {
                // Once the first EXECUTE is ACKed, upperBound covers the whole
                // firmware batch. Never intentionally divide an active refresh.
                if executionCount == 0 {
                    guard await clock.now() + upperBound + 5 < deadline else {
                        throw NeedResume(message: "表示更新を次のNFCセッションへ延期しました。同じ名刺を再スキャンしてください。")
                    }
                }
                work.sequence = ready.expectedSequence; work.offset = ready.expectedOffset
                work.executeSent = true // Set BEFORE awaiting the transport.
                work.refreshMayBeActive = true
                let ack = try await exchange(.execute, work: work, transport: transport)
                // FW may fall back to CHARGING without accepting EXECUTE.
                if ack.state == 2, ack.code == 3, ack.error == 0 {
                    work.refreshMayBeActive = false
                    executionDeferrals += 1
                    guard executionDeferrals <= 12 else { throw TransferError.chargingTimeout }
                    try await safePause(1, deadline: deadline)
                    ready = try await waitReady(work, transport: transport, deadline: deadline, onProgress: onProgress)
                    continue
                }
                if ack.error != 0 || ack.code == 0x80 { work.refreshMayBeActive = false }
                try ack.requireSuccess()
                work.executeAcknowledged = true
                work.sequence = ack.expectedSequence; work.offset = ack.expectedOffset
                if refreshLimit == nil { refreshLimit = await clock.now() + upperBound }
                executionCount += 1
                let batchActive = work.batch || (ack.capabilities & 0x10 != 0)
                let minimumQuiet = batchActive ? 1.0 : 2.0
                let quiet = max(minimumQuiet, Double(ack.quietMS) / 1_000) + 0.25
                emit(.refreshing, "e-paperを更新中です。\(Int(quiet * 1000))ms、RF通信を停止します。", onProgress, completed: imageBytes)
                // No deadline test here: cutting the session during refresh is
                // worse than waiting for Core NFC's own invalidation callback.
                try await clock.sleep(seconds: quiet)
            }
            if let refreshLimit, await clock.now() >= refreshLimit {
                throw HoldField(message: "表示更新の完了を制限時間内に確認できませんでした。表示は更新済みの可能性があります。端末を固定し、NFCセッション終了後に同じ名刺で再開してください。")
            }
            ready = try await confirmRefreshStatus(work, transport: transport,
                                                  deadline: min(deadline, refreshLimit ?? deadline),
                                                  onProgress: onProgress)
            if ready.state == 7 || ready.state == 0 || ready.state == 1 { work.refreshMayBeActive = false }
            try ready.requireSuccess()
            guard ready.expectedSequence == work.sequence, ready.expectedOffset == work.offset else {
                if ready.state == 6 { work.refreshMayBeActive = false }
                throw TransferError.inconsistentAcknowledgement
            }
            // Completion is accepted only in this connected run after the exact
            // target's EXECUTE ACK. Reconnection always replays the target.
            if ready.state == 6 && work.executeAcknowledged {
                work.refreshMayBeActive = false
                return ready
            }
            if ready.state == 0 || ready.state == 1 { throw TransferError.firmwareRestarted }
            if ready.state == 3 {
                work.refreshMayBeActive = false
                guard work.batch || (ready.capabilities & 0x10 != 0) else {
                    throw TransferError.inconsistentAcknowledgement
                }
                guard await clock.now() + 1.25 + 5 < deadline else {
                    throw NeedResume(message: "FWの次の更新段階を保留しました。同じ名刺を再スキャンしてください。")
                }
                try await clock.sleep(seconds: 1.5)
                continue
            }
            let quiet = max(1.0, Double(ready.quietMS) / 1_000)
            try await clock.sleep(seconds: quiet)
        }
    }

    private func confirmRefreshStatus(_ work: Work, transport: any MailboxTransport,
                                      deadline: TimeInterval,
                                      onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> NCAck {
        let timeout: TimeInterval = work.batch ? 3.5 : 1.5
        var attempt = 1
        while true {
            try Task.checkCancellation()
            guard await clock.now() < deadline else {
                throw HoldField(message: "完了確認の残り時間がありません。表示は更新済みの可能性があります。端末を固定し、NFCセッション終了後に同じ名刺で再開してください。")
            }
            do { return try await exchange(.status, work: work, transport: transport, timeout: timeout) }
            catch {
                try Task.checkCancellation()
                let recoverable: Bool
                switch error {
                case MailboxTransportError.transient, NCProtocolError.frame: recoverable = true
                default: recoverable = false
                }
                // STATUS is read-only in nc_transfer_apply/app.c. Re-read it
                // only on this connection after the previously required quiet.
                // A new tag, EXECUTE, or relaxed ACK checks cannot prove success.
                guard recoverable, attempt < 3 else { throw error }
                let quiet = max(work.batch ? 1.0 : 2.0, Double(work.lastAck?.quietMS ?? 0) / 1_000) + 0.25
                // Allow mailbox-free wait, ACK settle and timeout. Both the
                // refresh bound and the original session deadline still apply.
                guard await clock.now() + quiet + 1.1 + timeout < deadline else { throw error }
                attempt += 1
                emit(.refreshing, "表示更新の完了応答を確認し直しています（\(attempt)/3）。端末を固定してください。",
                     onProgress, completed: imageBytes)
                try await clock.sleep(seconds: quiet)
            }
        }
    }

    private func waitReady(_ work: Work, transport: any MailboxTransport, deadline: TimeInterval,
                           onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> NCAck {
        let chargeDeadline = min(await clock.now() + 12, deadline - 1.5)
        while await clock.now() < chargeDeadline {
            try await ensureExchangeTime(deadline)
            let ack = try await exchange(.status, work: work, transport: transport)
            try ack.requireSuccess()
            guard ack.expectedSequence == work.sequence, ack.expectedOffset == work.offset else {
                throw TransferError.firmwareRestarted
            }
            if ack.state == 3 { return ack }
            if ack.state == 0 || ack.state == 1 || ack.state == 6 { throw TransferError.firmwareRestarted }
            guard ack.state == 2 else { throw TransferError.inconsistentAcknowledgement }
            emit(.charging, "充電中: VDD \(ack.vddMV)mV", onProgress, completed: Int(work.offset))
            try await safePause(1, deadline: deadline)
        }
        throw TransferError.chargingTimeout
    }
}
