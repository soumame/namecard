import Combine
import CoreNFC
import Foundation

final class NFCController: NSObject, ObservableObject {
    static let patternNames = [
        "1. チェック柄", "2. NFC OK（文字）", "3. 全面黒", "4. 全面白",
        "5. 長辺方向の縞", "6. 短辺方向の縞", "7. グリッド",
        "8. 斜線", "9. ターゲット", "10. TEST 10（文字）"
    ]

    @Published private(set) var running = false
    @Published private(set) var logText = "試験を選び、iPhone上端を名刺へ固定してください。\n"
    @Published private(set) var imageName = "未選択"
    @Published private(set) var continuousNextPattern = 1
    @Published var selectedPatternID = 1

    private enum Operation {
        case status
        case silentPower
        case pattern(Int)
        case patternSequence
        case image
    }

    private final class ImageTransferState {
        let image: Data
        let metadata: Data
        let transferID: UInt16
        var sequence: UInt16 = 0
        var offset = 0
        var started = false
        var committed = false

        init(image: Data) {
            self.image = image
            metadata = NCProtocol.imageMetadata(for: image)
            transferID = NFCController.makeTransferID()
        }

        func resetProgress() {
            sequence = 0
            offset = 0
            started = false
            committed = false
        }
    }

    private let nfcQueue = DispatchQueue(label: "jp.namecard.nfctest.ios.corenfc")
    private var readerSession: NFCTagReaderSession?
    private var operation: Operation?
    private var sessionStartedAt = Date.distantPast
    private var performInFlight = false
    private var image: Data?
    private var imageTransfer: ImageTransferState?
    private var continuousCursor = 1

    func clearLog() {
        logText = ""
    }

    func loadImage(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let value = try Data(contentsOf: url)
            guard value.count == NCProtocol.imageSize else {
                throw NCClientError.invalidImageLength(value.count)
            }
            image = value
            imageTransfer = nil
            imageName = url.lastPathComponent
            appendLog("\(url.lastPathComponent) を読込済み（4,736 bytes）\n")
        } catch {
            appendLog("画像読込エラー: \(error.localizedDescription)\n")
        }
    }

    func loadBuiltInCheckerImage() {
        image = NCProtocol.checkerImage()
        imageTransfer = nil
        imageName = "内蔵 namecard-checker.bin"
        appendLog("内蔵チェック画像を読込済み（4,736 bytes）\n")
    }

    func startStatus() { start(.status, message: "STATUSを確認します") }
    func startSilentPowerTest() {
        start(.silentPower, message: "10秒間、Core NFCコマンドを止めて給電継続を確認します")
    }
    func startSelectedPattern() {
        start(.pattern(selectedPatternID),
              message: "\(Self.patternNames[selectedPatternID - 1]) を更新します")
    }
    func startPatternSequence(reset: Bool = true) {
        if reset {
            continuousCursor = 1
            continuousNextPattern = 1
        }
        start(.patternSequence,
              message: "内蔵パターンを\(continuousCursor)番から連続更新します")
    }
    func startImageTransfer() {
        guard image != nil else {
            appendLog("先に4,736-byte画像を選択してください。\n")
            return
        }
        start(.image, message: "画像を分割転送します")
    }

    private func start(_ newOperation: Operation, message: String) {
        guard !running else { return }
        guard NFCTagReaderSession.readingAvailable else {
            appendLog("このiPhoneではCore NFC Reader Sessionを利用できません。\n")
            return
        }
        operation = newOperation
        sessionStartedAt = Date()
        performInFlight = false
        running = true
        let session = NFCTagReaderSession(pollingOption: .iso15693,
                                          delegate: self, queue: nfcQueue)
        readerSession = session
        session?.alertMessage = message + "。iPhone上端を名刺へ固定してください。"
        appendLog("Core NFC開始: \(message)\n")
        session?.begin()
    }

    private func perform(_ operation: Operation, tag: NFCISO15693Tag,
                         session: NFCTagReaderSession) async {
        do {
            let mailbox = ST25Mailbox(tag: tag)
            try await sleep(milliseconds: 1_500)
            try await mailbox.enable()

            switch operation {
            case .status:
                try await runStatus(mailbox)
            case .silentPower:
                try await runSilentPowerTest(mailbox)
            case .pattern(let id):
                try await runPatternUpdate(mailbox, patternID: id)
            case .patternSequence:
                try await runPatternSequence(mailbox)
            case .image:
                try await runImageTransfer(mailbox)
            }
            session.alertMessage = "試験が完了しました"
            appendLog("セッション完了（\(elapsedString())）\n")
            session.invalidate()
        } catch {
            handle(error: error, session: session)
        }
    }

    private func runStatus(_ mailbox: ST25Mailbox) async throws {
        let ack = try await mailbox.exchange(NCProtocol.frame(
            type: NCProtocol.status, transferID: Self.makeTransferID(),
            sequence: 0, offset: 0))
        try ack.requireSuccess()
        appendLog(String(format:
            "STATUS OK: state=%d VDD=%dmV min=%dmV EH=%02X mailbox=%@\n",
            ack.state, ack.vddMillivolts, ack.minimumVDDMillivolts,
            ack.ehControl, ack.mailboxEnabled ? "ON" : "OFF"))
    }

    private func runSilentPowerTest(_ mailbox: ST25Mailbox) async throws {
        // START creates a volatile transfer marker (expected sequence=1)
        // without touching the EPD. If the MCU resets during silence, STATUS
        // returns sequence=0 and proves that continuous EH was lost.
        let markerImage = Data(repeating: 0xFF, count: NCProtocol.imageSize)
        let transferID = Self.makeTransferID()
        let startAck = try await mailbox.exchange(NCProtocol.frame(
            type: NCProtocol.start, transferID: transferID, sequence: 0,
            offset: 0, payload: NCProtocol.imageMetadata(for: markerImage)))
        try startAck.requireSuccess()
        guard startAck.expectedSequence == 1 else {
            throw NCClientError.mailboxResponse("silent-test marker was not accepted")
        }

        appendLog(String(format:
            "無通信開始: VDD=%dmV EH=%02X。ここから10秒間Core NFC APIを呼びません。\n",
            startAck.vddMillivolts, startAck.ehControl))
        try await sleep(milliseconds: 10_000)

        let after = try await mailbox.exchange(NCProtocol.frame(
            type: NCProtocol.status, transferID: transferID,
            sequence: 1, offset: 0))
        try after.requireSuccess()
        guard after.expectedSequence == 1, after.expectedOffset == 0 else {
            throw NCClientError.silentPowerLost
        }
        appendLog(String(format:
            "10秒無通信 PASS: MCU状態保持、VDD=%dmV min=%dmV EH=%02X\n",
            after.vddMillivolts, after.minimumVDDMillivolts, after.ehControl))
    }

    private func runPatternSequence(_ mailbox: ST25Mailbox) async throws {
        while continuousCursor <= Self.patternNames.count {
            guard elapsed < 48 else { throw NCClientError.sessionDeadline }
            let id = continuousCursor
            appendLog("連続 \(id)/10: \(Self.patternNames[id - 1])\n")
            try await runPatternUpdate(mailbox, patternID: id)
            continuousCursor = id + 1
            setContinuousNextPattern(id + 1)
        }
        appendLog("10種類の連続更新 PASS\n")
        continuousCursor = 1
        setContinuousNextPattern(1)
    }

    private func runPatternUpdate(_ mailbox: ST25Mailbox,
                                  patternID: Int) async throws {
        let transferID = Self.makeTransferID()
        let patternAck = try await mailbox.exchange(NCProtocol.frame(
            type: NCProtocol.pattern, transferID: transferID,
            sequence: 0, offset: 0, payload: Data([UInt8(patternID)])))
        try patternAck.requireSuccess()
        appendLog("PATTERN \(patternID) ACK、VRES充電待ち\n")

        if try await waitUntilReady(mailbox, transferID: transferID,
                                    sequence: 1, offset: NCProtocol.imageSize) {
            appendLog("PATTERN \(patternID) は更新済みでした。\n")
            return
        }
        try await executeRefresh(mailbox, transferID: transferID,
                                 sequence: 1, offset: NCProtocol.imageSize)
        appendLog("PATTERN \(patternID) 完了\n")
    }

    private func runImageTransfer(_ mailbox: ST25Mailbox) async throws {
        guard let image else { throw NCClientError.invalidImageLength(0) }
        if imageTransfer == nil || imageTransfer?.image != image {
            imageTransfer = ImageTransferState(image: image)
        }
        guard let transfer = imageTransfer else { return }
        appendLog("画像転送: \(transfer.offset) / \(NCProtocol.imageSize) bytesから開始\n")

        while !transfer.committed {
            guard elapsed < 52 else { throw NCClientError.sessionDeadline }
            if !transfer.started {
                let ack = try await mailbox.exchange(NCProtocol.frame(
                    type: NCProtocol.start, transferID: transfer.transferID,
                    sequence: 0, offset: 0, payload: transfer.metadata))
                try ack.requireSuccess()
                transfer.started = true
                transfer.sequence = ack.expectedSequence
                transfer.offset = Int(ack.expectedOffset)
                appendLog("START ACK。500ms蓄電します。\n")
                try await sleep(milliseconds: 500)
                continue
            }

            if transfer.offset < image.count {
                let start = transfer.offset
                let end = min(start + NCProtocol.dataPayloadSize, image.count)
                let chunk = image.subdata(in: start..<end)
                let ack = try await mailbox.exchange(NCProtocol.frame(
                    type: NCProtocol.data, transferID: transfer.transferID,
                    sequence: transfer.sequence, offset: UInt16(start), payload: chunk))
                if ack.error == 7 {
                    appendLog("MCU再起動を検出。STARTから再開します。\n")
                    transfer.resetProgress()
                    continue
                }
                if (ack.error == 8 || ack.error == 9),
                   Int(ack.expectedOffset) <= NCProtocol.imageSize {
                    transfer.sequence = ack.expectedSequence
                    transfer.offset = Int(ack.expectedOffset)
                    appendLog("FW期待位置へ再同期: \(transfer.offset) bytes\n")
                    continue
                }
                try ack.requireSuccess()
                transfer.sequence = ack.expectedSequence
                transfer.offset = Int(ack.expectedOffset)
                appendLog("\(transfer.offset) / \(NCProtocol.imageSize) bytes, VDD=\(ack.vddMillivolts)mV\n")
                if transfer.offset < image.count { try await sleep(milliseconds: 500) }
                continue
            }

            let commitAck = try await mailbox.exchange(NCProtocol.frame(
                type: NCProtocol.commit, transferID: transfer.transferID,
                sequence: transfer.sequence, offset: UInt16(NCProtocol.imageSize)))
            if commitAck.error == 7 {
                transfer.resetProgress()
                continue
            }
            try commitAck.requireSuccess()
            transfer.sequence = commitAck.expectedSequence
            transfer.offset = Int(commitAck.expectedOffset)
            transfer.committed = true
            appendLog("COMMIT ACK\n")
        }

        do {
            if try await waitUntilReady(mailbox, transferID: transfer.transferID,
                                        sequence: transfer.sequence,
                                        offset: transfer.offset) {
                imageTransfer = nil
                appendLog("画像は更新済みでした。\n")
                return
            }
        } catch NCClientError.firmware(let code, _) where code == 7 {
            // The phone can lose the field after COMMIT or EXECUTE. In that
            // case the local committed flag must not trap subsequent sessions
            // in STATUS-only retries against a freshly booted MCU.
            transfer.resetProgress()
            appendLog("更新前にMCUが再起動。画像をSTARTから再送します。\n")
            throw NCClientError.firmware(7, "MCU reset")
        }
        try await executeRefresh(mailbox, transferID: transfer.transferID,
                                 sequence: transfer.sequence, offset: transfer.offset)
        imageTransfer = nil
        appendLog("画像更新 PASS\n")
    }

    // Returns true if a prior EXECUTE already completed before reconnection.
    private func waitUntilReady(_ mailbox: ST25Mailbox, transferID: UInt16,
                                sequence: UInt16, offset: Int) async throws -> Bool {
        appendLog("1.5秒間、RFコマンドを止めてVRESを充電します。\n")
        try await sleep(milliseconds: 1_500)
        while true {
            guard elapsed < 55 else { throw NCClientError.sessionDeadline }
            let ack = try await mailbox.exchange(NCProtocol.frame(
                type: NCProtocol.status, transferID: transferID,
                sequence: sequence, offset: UInt16(offset)))
            try ack.requireSuccess()
            appendLog("充電: state=\(ack.state) VDD=\(ack.vddMillivolts)mV min=\(ack.minimumVDDMillivolts)mV\n")
            if ack.state == 6 { return true }
            if ack.state == 1, ack.expectedSequence == 0 {
                throw NCClientError.firmware(7, "MCU reset")
            }
            if ack.state == 3 { return false }
            try await sleep(milliseconds: 1_000)
        }
    }

    private func executeRefresh(_ mailbox: ST25Mailbox, transferID: UInt16,
                                sequence: UInt16, offset: Int) async throws {
        let executeAck = try await mailbox.exchange(NCProtocol.frame(
            type: NCProtocol.execute, transferID: transferID,
            sequence: sequence, offset: UInt16(offset)))
        try executeAck.requireSuccess()
        let quiet = max(2_000, Int(executeAck.quietMilliseconds))
        appendLog("EXECUTE ACK。\(quiet)ms、Core NFCコマンドを止めます。\n")
        try await sleep(milliseconds: quiet + 250)

        let complete = try await mailbox.exchange(NCProtocol.frame(
            type: NCProtocol.status, transferID: transferID,
            sequence: sequence + 1, offset: UInt16(offset)))
        try complete.requireSuccess()
        guard complete.state == 6 else {
            throw NCClientError.updateIncomplete(Int(complete.state), Int(complete.error))
        }
        appendLog("更新中min VDD=\(complete.minimumVDDMillivolts)mV\n")
    }

    private func handle(error: Error, session: NFCTagReaderSession) {
        appendLog("失敗: \(error.localizedDescription)（\(elapsedString())）\n")
        performInFlight = false
        if shouldRetry(error), elapsed < 52 {
            session.alertMessage = "位置を合わせ直してください。進捗を保持して再検出します。"
            appendLog("同じCore NFCセッションで再検出します。\n")
            session.restartPolling()
        } else {
            if case NCClientError.sessionDeadline = error,
               case .patternSequence? = operation {
                appendLog("連続試験は\(continuousCursor)番から続行できます。\n")
            }
            session.invalidate(errorMessage: error.localizedDescription)
        }
    }

    private func shouldRetry(_ error: Error) -> Bool {
        guard let client = error as? NCClientError else { return true }
        switch client {
        case .mailboxBusy, .mailboxResponse:
            return true
        case .firmware(let code, _):
            return code == 7 || code == 8 || code == 9 || code == 18
        default:
            return false
        }
    }

    private var elapsed: TimeInterval { Date().timeIntervalSince(sessionStartedAt) }
    private func elapsedString() -> String { String(format: "%.1f秒", elapsed) }

    private func sleep(milliseconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    private func appendLog(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.logText.append(message) }
    }

    private func setContinuousNextPattern(_ value: Int) {
        DispatchQueue.main.async { [weak self] in self?.continuousNextPattern = value }
    }

    private static func makeTransferID() -> UInt16 {
        UInt16.random(in: 1...UInt16.max)
    }
}

extension NFCController: NFCTagReaderSessionDelegate {
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        appendLog("RF polling開始。タグを探しています。\n")
    }

    func tagReaderSession(_ session: NFCTagReaderSession,
                          didDetect tags: [NFCTag]) {
        guard !performInFlight else { return }
        guard tags.count == 1 else {
            session.alertMessage = "名刺を1枚だけ近づけてください"
            session.restartPolling()
            return
        }
        guard case .iso15693(let isoTag) = tags[0], let operation else {
            session.invalidate(errorMessage: NCClientError.unsupportedTag.localizedDescription)
            return
        }

        performInFlight = true
        appendLog("ISO 15693検出 UID=\(isoTag.identifier.map { String(format: "%02X", $0) }.joined())\n")
        session.connect(to: tags[0]) { [weak self] error in
            guard let self else { return }
            if let error {
                self.performInFlight = false
                self.appendLog("接続失敗: \(error.localizedDescription)。再検出します。\n")
                session.restartPolling()
                return
            }
            Task { await self.perform(operation, tag: isoTag, session: session) }
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession,
                          didInvalidateWithError error: Error) {
        performInFlight = false
        readerSession = nil
        DispatchQueue.main.async { [weak self] in self?.running = false }
        let readerError = error as? NFCReaderError
        if readerError?.code != .readerSessionInvalidationErrorUserCanceled {
            appendLog("Core NFC終了: \(error.localizedDescription)\n")
        }
    }
}
