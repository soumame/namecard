import Foundation
import NamecardCore

enum URLMemoryStatus { case readWrite(Int), readOnly, notSupported }

protocol URLTagTransport: Sendable {
    var identifier: Data { get }
    func checkConnection() throws
    func setEnabled(_ enabled: Bool) async throws
    func exchange(_ frame: NCFrame, timeout: TimeInterval) async throws -> NCAck
    func readMemory() async throws -> Data
    func blankIdentity() async throws -> Type5Identity
    func ndefStatus() async throws -> URLMemoryStatus
    func writeMessage(_ message: Data) async throws
    func writeBlock(_ write: Type5BlockWrite) async throws
}

struct URLWriteJournal: Codable {
    let uid: Data
    let url: String
    let message: Data
    var originalMemory: Data?
    var writes: [Type5BlockWrite]?
    // Optional for compatibility with journals saved before URL clearing existed.
    var clearsURL: Bool?

    var operation: URLUpdate { clearsURL == true ? .clear : .set(url) }
}

/// Kept on disk before touching EEPROM, including the exact blank-format write plan.
struct URLJournalStore {
    let file: URL
    func load() throws -> URLWriteJournal? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(URLWriteJournal.self, from: Data(contentsOf: file))
    }
    func save(_ journal: URLWriteJournal) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: file, options: .atomic)
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

enum URLWriter {
    static func write(_ operation: URLUpdate, mailbox: any URLTagTransport, store: URLJournalStore,
                      sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                          try await Task.sleep(for: .seconds(seconds))
                      },
                      progress: @escaping @Sendable (String) -> Void) async throws {
        let operation = try operation.normalized()
        let expected = try operation.ndefMessage()
        let uid = mailbox.identifier
        let prior = try store.load()
        if let prior, prior.uid != uid || prior.message != expected || prior.operation != operation {
            throw AppFailure("未完了のURL操作があります。Settingsから元の名刺で再開してください。")
        }
        let url: String
        if case .set(let value) = operation { url = value } else { url = "" }
        var journal = prior ?? URLWriteJournal(uid: uid, url: url, message: expected, clearsURL: operation.isClear ? true : nil)
        progress("名刺を準備しています")
        try await sleep(1.5)
        try await mailbox.setEnabled(true)
        let request = NCFrame(command: .ndefWritePrepare, transferID: UInt16.random(in: 1...UInt16.max))
        var writeMayHaveStarted = false
        do {
            let ack = try await mailbox.exchange(request, timeout: 1.5)
            guard ack.error != 6 else { throw AppFailure("この名刺ではURL設定を利用できません。") }
            try ack.requireSuccess()
            // Include persistence failures in restoration: the MCU may already
            // have paused its Mailbox after the PREPARE ACK was read.
            try store.save(journal)
            try await mailbox.setEnabled(false)
            progress(operation.isClear ? "URLをクリアしています" : "URLを書き込んでいます")
            let memory = try await mailbox.readMemory()
            if let writes = journal.writes, let original = journal.originalMemory {
                try validateReplay(memory: memory, original: original, writes: writes)
                let identity = try await mailbox.blankIdentity()
                let canonical = try URLCodec.blankType5WritePlan(memory: original, message: expected, identity: identity)
                guard writes == canonical else { throw AppFailure("URLの復旧記録が不正です。初期化を停止しました。") }
                writeMayHaveStarted = true
                try await apply(writes, mailbox: mailbox)
            } else {
                let status = try await mailbox.ndefStatus()
                switch status {
                case .readWrite(let capacity):
                    guard expected.count <= capacity else { throw AppFailure("URLが名刺の保存容量を超えています。") }
                    writeMayHaveStarted = true
                    try await mailbox.writeMessage(expected)
                case .notSupported:
                    let identity = try await mailbox.blankIdentity()
                    let writes = try URLCodec.blankType5WritePlan(memory: memory, message: expected, identity: identity)
                    journal.originalMemory = memory
                    journal.writes = writes
                    try store.save(journal)
                    writeMayHaveStarted = true
                    try await apply(writes, mailbox: mailbox)
                case .readOnly:
                    throw AppFailure("この名刺のURL領域は書き込み禁止です。")
                }
            }
            progress("URLを読み返して確認しています")
            let actual = try await mailbox.readMemory()
            guard try URLCodec.type5NDEF(in: actual) == expected else {
                throw AppFailure("URLの読み返しが一致しません。同じ名刺で再開してください。")
            }
            try await mailbox.setEnabled(true)
            try store.clear()
        } catch {
            // A read-only/unknown tag can fail before any EEPROM mutation. Do
            // not trap all future operations behind an unnecessary fresh journal.
            // Existing or possibly-written jobs survive any ambiguous failure.
            if (try? await mailbox.setEnabled(true)) != nil,
               prior == nil, !writeMayHaveStarted {
                try? store.clear()
            }
            throw error
        }
    }

    static func validateReplay(memory: Data, original: Data, writes: [Type5BlockWrite]) throws {
        guard memory.count == 512, original.count == 512 else { throw AppFailure("復旧記録の長さが不正です。") }
        for block in 0..<128 {
            let range = block * 4..<(block + 1) * 4
            let actual = memory.subdata(in: range)
            let candidates = [original.subdata(in: range)] + writes.filter { $0.block == block }.map(\.bytes)
            guard candidates.contains(actual) else {
                throw AppFailure("未完了の処理後に名刺の内容が変更されています。自動初期化を停止しました。")
            }
        }
    }

    private static func apply(_ writes: [Type5BlockWrite], mailbox: any URLTagTransport) async throws {
        for write in writes {
            try mailbox.checkConnection()
            guard (0..<128).contains(write.block), write.bytes.count == 4 else { throw AppFailure("復旧記録が不正です。") }
            try await mailbox.writeBlock(write)
        }
    }
}
