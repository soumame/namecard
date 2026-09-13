@preconcurrency import CoreNFC
import Foundation
import NamecardCore
import Observation
import UIKit

@MainActor @Observable
// The delegate is always installed on queue .main below. The SDK's Objective-C
// protocol does not express that actor guarantee.
final class NFCService: NSObject, @preconcurrency NFCTagReaderSessionDelegate {
    var isScanning = false
    var isPreparing = false
    var showsProgress = false
    var message = "書き込み内容を選択してください"
    var fraction = 0.0
    var succeeded = false
    var pending = false
    var lastVDD: UInt16?
    var responseMS = 0
    var issues = 0
    var log = ""
    var recoveryURL: URLUpdate?
    let hapticGuide = NFCHapticGuide()
    var isBusy: Bool { isScanning || isPreparing }
    var supportsNFC: Bool { NFCTagReaderSession.readingAvailable }

    @ObservationIgnored private let coordinator = TransferCoordinator()
    @ObservationIgnored private let journalStore: URLJournalStore
    @ObservationIgnored private var session: NFCTagReaderSession?
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var deadline: TimeInterval = 0
    @ObservationIgnored private var pendingWrite: Request?
    @ObservationIgnored private var sessionRequest: Request?
    @ObservationIgnored private var retainedTransfer = false
    @ObservationIgnored private var acceptsProgress = false
    @ObservationIgnored private var sessionEndReason: String?
    @ObservationIgnored private var issueRecorded = false
    @ObservationIgnored private var rediscovery = TransferRediscovery()
    @ObservationIgnored private var sessionTiming = NFCSessionTiming()
    @ObservationIgnored private var alertRateLimit = NFCAlertRateLimit()
    @ObservationIgnored private var progressUpdatedAt: TimeInterval = -.infinity
    @ObservationIgnored private var lastProgressPhase: TransferProgress.Phase?
    @ObservationIgnored private let logStartedAt = ProcessInfo.processInfo.systemUptime
    private enum Request: Sendable { case transfer, url(URLUpdate), status }

    init(directory: URL) {
        journalStore = URLJournalStore(file: directory.appendingPathComponent("url-write-journal.json"))
        super.init()
        hapticGuide.onEvent = { [weak self] event in
            let appState: String
            switch UIApplication.shared.applicationState {
            case .active: appState = "active"
            case .inactive: appState = "inactive"
            case .background: appState = "background"
            @unknown default: appState = "unknown"
            }
            self?.appendLog("触覚案内: \(event) app=\(appState)")
        }
        refreshJournal()
    }

    func writeImage(_ data: Data, clean: Bool) {
        prepare {
            guard HardwareValidation.allowsDisplayWrites else { throw AppFailure(HardwareValidation.explanation) }
            try await self.coordinator.prepareImage(data, cleanBeforeWrite: clean)
            self.retainedTransfer = true
            return .transfer
        }
    }
    func writePattern(_ id: UInt8) {
        prepare {
            guard HardwareValidation.allowsDisplayWrites else { throw AppFailure(HardwareValidation.explanation) }
            try await self.coordinator.preparePattern(id)
            self.retainedTransfer = true
            return .transfer
        }
    }
    func writeSequence() {
        prepare {
            guard HardwareValidation.allowsDisplayWrites else { throw AppFailure(HardwareValidation.explanation) }
            try await self.coordinator.prepareSequence()
            self.retainedTransfer = true
            return .transfer
        }
    }
    func readStatus() {
        // Diagnostics must not replace the coordinator's UID-bound paused image.
        // EEPROM recovery still takes precedence because STATUS re-enables FTM.
        prepare { .status }
    }
    func updateURL(_ operation: URLUpdate) {
        prepare(allowURLRecovery: true) {
            let normalized = try operation.normalized()
            let expected = try normalized.ndefMessage()
            if let old = try self.journalStore.load(), old.operation != normalized || old.message != expected {
                throw AppFailure("未完了のURL操作を元の名刺で再開してください。")
            }
            return .url(normalized)
        }
    }
    func resumeURL() { if let recoveryURL { updateURL(recoveryURL) } }
    func resume() {
        guard !isBusy, let pendingWrite else { return }
        begin(pendingWrite)
    }
    func clearLog() { log = "" }
    func previewPlacementHaptics() {
        guard !isBusy, hapticGuide.enabled, hapticGuide.supported else { return }
        hapticGuide.preview()
        appendLog("触覚案内: 確認用の短い振動を要求しました（実際の振動は端末で確認）。")
    }

    private func prepare(allowURLRecovery: Bool = false, _ work: @escaping () async throws -> Request) {
        guard !isBusy else { return }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                if !allowURLRecovery, try journalStore.load() != nil {
                    throw AppFailure("先に未完了のURL操作を元の名刺で再開してください。")
                }
                let selected = try await work()
                switch selected {
                case .status: break
                case .transfer, .url: pendingWrite = selected
                }
                pending = pendingWrite != nil
                guard UIApplication.shared.applicationState == .active else {
                    message = "操作内容を保持しました。アプリに戻って再スキャンしてください。"
                    return
                }
                begin(selected)
            } catch { show(error) }
        }
    }

    private func begin(_ selected: Request) {
        guard session == nil else { return }
        guard UIApplication.shared.applicationState == .active else {
            message = "アプリに戻って同じ名刺を再スキャンしてください。"
            return
        }
        showsProgress = true
        hapticGuide.stop()
        succeeded = false
        lastVDD = nil
        responseMS = 0
        issues = 0
        fraction = 0
        acceptsProgress = false
        sessionEndReason = nil
        issueRecorded = false
        guard supportsNFC else {
            message = "この環境ではNFCを利用できません。NFC対応のiPhone実機で確認してください。"
            return
        }
        generation = UUID()
        deadline = ProcessInfo.processInfo.systemUptime + 60
        rediscovery = TransferRediscovery()
        alertRateLimit = NFCAlertRateLimit()
        progressUpdatedAt = -.infinity
        lastProgressPhase = nil
        appendLog("端末=\(HardwareValidation.model) OS=\(ProcessInfo.processInfo.operatingSystemVersionString) DATA=128 bytes")
        appendLog("配布設定=\(HardwareValidation.distributionChannel) ベータ試験=\(HardwareValidation.profile.isBetaTesting)")
        appendLog("触覚案内: 設定=\(hapticGuide.enabled ? "ON" : "OFF") 対応=\(hapticGuide.supported)。既存ACKのみ使用。")
        message = "iPhoneの上端を名刺のアンテナに重ね、動かさないでください。"
        guard let reader = NFCTagReaderSession(pollingOption: [.iso15693], delegate: self, queue: .main) else {
            message = "NFCセッションを開始できませんでした。もう一度操作してください。"
            return
        }
        session = reader
        sessionRequest = selected
        isScanning = true
        acceptsProgress = true
        UIApplication.shared.isIdleTimerDisabled = true
        setMessage(message)
        reader.begin()
    }

    func backgrounded() {
        hapticGuide.stop()
        // Core NFC invalidates background sessions itself. Do not deliberately
        // cut the field here: an EXECUTE may still be refreshing the panel.
        guard isScanning else { return }
        acceptsProgress = false
        let reason = "アプリが背景へ移動しました。同じ名刺で再開してください。"
        sessionEndReason = reason
        message = reason
        activeTask?.cancel()
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        guard self.session === session else { return }
        sessionTiming.becameActive()
        appendLog("NFCセッション開始。最大60秒。")
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        guard self.session === session else { return }
        hapticGuide.stop()
        let finishingTask = activeTask
        finishingTask?.cancel()
        activeTask = nil
        self.session = nil
        sessionRequest = nil
        generation = UUID() // Reject all callbacks queued by the old task.
        let cleanupToken = generation
        acceptsProgress = false
        isScanning = false
        // Wait for cancellation to leave the coordinator before allowing a new
        // session. Otherwise the new run can race the old actor's cleanup.
        isPreparing = true
        let nsError = error as NSError
        let systemBusy = nsError.domain == NFCErrorDomain &&
            nsError.code == NFCReaderError.Code.readerSessionInvalidationErrorSystemIsBusy.rawValue
        let cooldown = sessionTiming.ended(systemBusy: systemBusy)
        let canRestartAt = ProcessInfo.processInfo.systemUptime + cooldown
        UIApplication.shared.isIdleTimerDisabled = false
        if !succeeded {
            recordIssue()
            message = systemBusy ? "iOSのNFCが使用中です。\(Int(cooldown))秒待ってから、同じ名刺を再スキャンしてください。" : sessionEndReason ?? (pendingWrite != nil
                ? "接続が終了しました（\(error.localizedDescription)）。同じ名刺で再開してください。"
                : "NFCスキャンが終了しました（\(error.localizedDescription)）。")
            appendLog("セッション終了: \(error.localizedDescription)")
        }
        refreshJournal()
        appendLog("NFC終了処理と再開始待機: \(Int(cooldown))秒 code=\(nsError.code)")
        Task { [weak self] in
            await finishingTask?.value
            let remaining = max(0, canRestartAt - ProcessInfo.processInfo.systemUptime)
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, self.generation == cleanupToken, self.session == nil else { return }
            self.isPreparing = false
            self.appendLog("NFC終了処理完了。再スキャンできます。")
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard self.session === session, activeTask == nil, let selected = sessionRequest else { return }
        guard tags.count == 1, case .iso15693(let tag) = tags[0], tag.icManufacturerCode == 2 else {
            session.alertMessage = "対応する名刺を1枚だけ重ねてください。"
            session.restartPolling()
            return
        }
        if let expected = rediscovery.uid, expected != tag.identifier {
            let reason = "別の名刺を検出しました。前回と同じ名刺で再開してください。"
            finishMessage(reason)
            session.invalidate(errorMessage: reason)
            return
        }
        let token = generation
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                do {
                    try await CancellableNFCRequest.run { @MainActor in try await session.connect(to: tags[0]) }
                } catch { throw ST25Mailbox.transportError(error) }
                guard isCurrent(session, token: token), !Task.isCancelled else { return }
                appendLog("検出 UID=\(tag.identifier.map { String(format: "%02X", $0) }.joined())")
                let mailbox = ST25Mailbox(tag: tag, deadline: deadline, onEvent: { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.isCurrent(token: token) else { return }
                        self.appendLog("\(event) 残り=\(self.remainingSeconds)s")
                    }
                }) { [weak self] ack, elapsed in
                    Task { @MainActor in
                        guard let self, self.isCurrent(token: token) else { return }
                        self.lastVDD = ack.vddMV
                        self.responseMS = Int(elapsed * 1000)
                        self.appendLog("ACK type=\(ack.acknowledgedType) id=\(ack.transferID) reqSeq=\(ack.requestSequence) code=\(ack.code) state=\(ack.state) seq=\(ack.expectedSequence) offset=\(ack.expectedOffset) VDD=\(ack.vddMV) min=\(ack.minimumVddMV) quiet=\(ack.quietMS) flags=\(String(format: "%02X", ack.capabilities)) error=\(ack.error) \(self.responseMS)ms 残り=\(self.remainingSeconds)s")
                    }
                }
                switch selected {
                case .transfer:
                    hapticGuide.begin(connection: token)
                    let observed = FeedbackMailbox(transport: mailbox, guide: hapticGuide, connection: token)
                    let transport = RetryingDataMailbox(transport: observed, deadline: deadline) { [weak self] frame, attempt, reason in
                        Task { @MainActor in
                            guard let self, self.isCurrent(token: token), self.acceptsProgress else { return }
                            self.appendLog("DATA再送 \(attempt)/3 seq=\(frame.sequence) offset=\(frame.offset): \(reason)")
                            self.setMessage("通信を再試行中です（\(attempt)/3）。\(frame.offset) / 4736 bytes。端末を固定してください。", force: false)
                        }
                    }
                    let result = try await coordinator.run(transport: transport, uid: tag.identifier,
                                                           deadline: deadline, policy: HardwareValidation.profile) { [weak self] progress in
                        Task { @MainActor in
                            guard let self, self.isCurrent(token: token), self.acceptsProgress else { return }
                            let now = ProcessInfo.processInfo.systemUptime
                            let phaseChanged = self.lastProgressPhase != progress.phase
                            guard phaseChanged || now - self.progressUpdatedAt >= 0.25 else { return }
                            self.progressUpdatedAt = now
                            self.lastProgressPhase = progress.phase
                            self.setMessage(progress.message, force: phaseChanged)
                            self.fraction = progress.phase == .completed ? 1 : min(0.9, progress.fraction * 0.75)
                        }
                    }
                    guard isCurrent(session, token: token), !Task.isCancelled else { return }
                    switch result {
                    case .completed(let ack):
                        retainedTransfer = false
                        pendingWrite = nil
                        complete(ack.error == 0 ? "処理が完了しました。" : "FW error=\(ack.error)", session: session)
                    case .resumeNeeded(let reason):
                        finishMessage(reason)
                        session.invalidate(errorMessage: reason)
                    case .holdField(let reason):
                        let heldState = await coordinator.pending
                        guard isCurrent(session, token: token), !Task.isCancelled else { return }
                        if let state = heldState {
                            let ack = state.lastAck
                            appendLog("完了確認保留: id=\(state.transferID?.description ?? "--") EXECUTE_ACK=\(state.executeAcknowledged) 最終ACK state=\(ack?.state.description ?? "--") seq=\(state.expectedSequence) offset=\(state.expectedOffset) quiet=\(ack?.quietMS.description ?? "--") 残り=\(remainingSeconds)s")
                        }
                        finishMessage(reason)
                        // Keep activeTask occupied. No app timer ends RF while the EPD may run.
                        return
                    }
                case .url(let url):
                    try await URLWriter.write(url, mailbox: mailbox, store: journalStore) { [weak self] text in
                        Task { @MainActor in
                            guard let self, self.isCurrent(token: token), self.acceptsProgress else { return }
                            self.setMessage(text)
                        }
                    }
                    guard isCurrent(session, token: token), !Task.isCancelled else { return }
                    refreshJournal()
                    pendingWrite = retainedTransfer ? .transfer : nil
                    complete(url.isClear ? "URLをクリアし、読み返して確認しました。" : "URLを書き込み、読み返して確認しました。", session: session)
                case .status:
                    setMessage("MCU起動のため1.5秒待ちます。端末を固定してください。")
                    try await Task.sleep(for: .milliseconds(1500))
                    let frame = NCFrame(command: .status, transferID: UInt16.random(in: 1...UInt16.max))
                    let ack = try await mailbox.exchange(frame, timeout: 1.5)
                    guard isCurrent(session, token: token), !Task.isCancelled else { return }
                    let detail = "STATUS: state=\(ack.state) VDD=\(ack.vddMV)mV min=\(ack.minimumVddMV)mV error=\(ack.error)"
                    if ack.state == 4 || ack.state == 5 {
                        finishMessage(detail + "。名刺側の更新中です。セッションが終了するまで端末を固定してください。")
                        return // Diagnostics must not cut an existing refresh.
                    }
                    complete(detail, session: session)
                }
            } catch {
                guard isCurrent(session, token: token), !Task.isCancelled else { return }
                recordIssue()
                finishMessage(error.localizedDescription)
                refreshJournal()
                // An error after EXECUTE may still have left the EPD updating.
                let state = await coordinator.pending
                guard isCurrent(session, token: token), !Task.isCancelled else { return }
                if case .transfer = selected, let state {
                    let request = state.unconfirmedCommand
                    appendLog("転送中断: ACK位置=\(state.expectedOffset) seq=\(state.expectedSequence) 未確認NC=\(request?.type.description ?? "--") offset=\(request?.offset.description ?? "--") 残り=\(remainingSeconds)s")
                    if state.transferID == nil {
                        appendLog("再開位置を破棄しました。元画像とUIDを保持し、次のスキャンでSTARTから再送します。")
                    }
                }
                if state?.refreshMayBeActive == true, case .transfer = selected {
                    finishMessage("\(error.localizedDescription)\n表示更新の確認が中断しました。セッションが終了するまで端末を固定してください。")
                    return
                }
                if case .transfer = selected,
                   case MailboxTransportError.connectionLost = error,
                   rediscovery.reserve(snapshot: state, now: ProcessInfo.processInfo.systemUptime, deadline: deadline) {
                    acceptsProgress = true
                    sessionEndReason = nil
                    setMessage("接続を取り直しています（\(rediscovery.attempts)/\(TransferRediscovery.maximumAttempts)）。同じ名刺の位置を保ってください。")
                    appendLog("同じUIDを再検出します。RAMが失われていればSTARTから再送します。")
                    do { try await Task.sleep(for: .milliseconds(500)) }
                    catch { return }
                    guard isCurrent(session, token: token), !Task.isCancelled else { return }
                    // Old Core NFC tag objects become invalid after restartPolling.
                    // End this task and obtain a new tag through didDetect; the
                    // original 60-second deadline and UID-bound job stay intact.
                    generation = UUID()
                    activeTask = nil
                    session.restartPolling()
                    return
                }
                session.invalidate(errorMessage: error.localizedDescription)
            }
        }
    }

    private func complete(_ text: String, session: NFCTagReaderSession) {
        hapticGuide.stop()
        acceptsProgress = false
        succeeded = true
        pending = pendingWrite != nil
        fraction = 1
        setMessage(text)
        appendLog(text)
        session.invalidate()
    }
    private func isCurrent(_ session: NFCTagReaderSession, token: UUID) -> Bool {
        self.session === session && generation == token && isScanning
    }
    private func isCurrent(token: UUID) -> Bool {
        session != nil && generation == token && isScanning
    }
    private func finishMessage(_ text: String) {
        hapticGuide.stop()
        acceptsProgress = false
        sessionEndReason = text
        setMessage(text)
        appendLog(text)
    }
    private func recordIssue() {
        guard !issueRecorded else { return }
        issues += 1
        issueRecorded = true
    }
    private func setMessage(_ text: String, force: Bool = true) {
        if message != text { message = text }
        if let session, alertRateLimit.shouldSend(text, now: ProcessInfo.processInfo.systemUptime, force: force) {
            session.alertMessage = text
        }
    }
    private var remainingSeconds: String {
        String(format: "%.1f", max(0, deadline - ProcessInfo.processInfo.systemUptime))
    }
    private func show(_ error: Error) {
        message = error.localizedDescription
        showsProgress = true
        succeeded = false
        appendLog(message)
    }
    private func refreshJournal() {
        do { recoveryURL = try journalStore.load()?.operation }
        catch {
            let detail = "URLの復旧記録を読み込めません: \(error.localizedDescription)"
            if sessionEndReason == nil && !succeeded { message = detail }
            appendLog(detail)
        }
    }
    private func appendLog(_ text: String) {
        let elapsed = String(format: "%.3f", max(0, ProcessInfo.processInfo.systemUptime - logStartedAt))
        log += "[+\(elapsed)s] \(text)\n"
        if log.count > 50_000 { log = String(log.suffix(40_000)) }
    }
}
