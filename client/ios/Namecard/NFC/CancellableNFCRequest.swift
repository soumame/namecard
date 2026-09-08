import Foundation

/// Core NFC may deliver a command callback after the session's invalidation
/// callback. Cancellation must release the app's task without waiting for it.
enum CancellableNFCRequest {
    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let gate = RequestGate<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                let worker = Task {
                    do {
                        try Task.checkCancellation()
                        guard gate.canStart else { throw CancellationError() }
                        gate.finish(.success(try await operation()))
                    } catch { gate.finish(.failure(error)) }
                }
                gate.install(worker)
            }
        } onCancel: { gate.cancel() }
    }
}

private final class RequestGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Value, Error>?
    private var worker: Task<Void, Never>?

    var canStart: Bool { lock.withLock { !finished } }

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let accepted = lock.withLock {
            if finished { return false }
            self.continuation = continuation
            return true
        }
        if !accepted { continuation.resume(throwing: CancellationError()) }
        return accepted
    }

    func install(_ worker: Task<Void, Never>) {
        let cancel = lock.withLock {
            if finished { return true }
            self.worker = worker
            return false
        }
        if cancel { worker.cancel() }
    }

    func finish(_ result: Result<Value, Error>) {
        let callback = lock.withLock {
            if finished { return nil as CheckedContinuation<Value, Error>? }
            finished = true
            worker = nil
            defer { continuation = nil }
            return continuation
        }
        callback?.resume(with: result)
    }

    func cancel() {
        let pending = lock.withLock {
            finished = true
            defer { continuation = nil; worker = nil }
            return (continuation, worker)
        }
        pending.1?.cancel()
        pending.0?.resume(throwing: CancellationError())
    }
}
