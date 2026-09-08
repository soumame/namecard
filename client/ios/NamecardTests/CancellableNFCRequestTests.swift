import XCTest
@testable import Namecard

private actor DelayedNFCResponse {
    var callback: CheckedContinuation<Int, Error>?
    func read(started: XCTestExpectation) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            callback = continuation
            started.fulfill()
        }
    }
    func complete(_ result: Result<Int, Error>) {
        callback?.resume(with: result)
        callback = nil
    }
}

final class CancellableNFCRequestTests: XCTestCase {
    func testInvalidationReleasesTaskBeforeNativeCallbackAndIgnoresLateResult() async {
        for lateFailure in [false, true] {
            let native = DelayedNFCResponse()
            let started = expectation(description: "Native I/O started")
            let released = expectation(description: "App task released by cancellation")
            let task = Task {
                do {
                    _ = try await CancellableNFCRequest.run { try await native.read(started: started) }
                    XCTFail("Cancelled request succeeded")
                } catch { XCTAssertTrue(error is CancellationError) }
                released.fulfill()
            }
            await fulfillment(of: [started], timeout: 2)
            task.cancel()
            await fulfillment(of: [released], timeout: 2)
            // Only now does the native SDK deliver its result/error.
            await native.complete(lateFailure ? .failure(NSError(domain: "NFCError", code: 100)) : .success(42))
            await task.value
            do {
                let fresh = try await CancellableNFCRequest.run { 99 }
                XCTAssertEqual(fresh, 99)
            } catch { XCTFail("A cancelled request poisoned the next request: \(error)") }
        }
    }

    func testCancellationBeforeStartingDoesNotIssueCommand() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await CancellableNFCRequest.run { XCTFail("Command issued after cancellation"); return 1 }
                XCTFail("Request succeeded")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
    }

    func testNativeSuccessAndFailureRemainVisible() async {
        do {
            let value = try await CancellableNFCRequest.run { 42 }
            XCTAssertEqual(value, 42)
        } catch { XCTFail("\(error)") }
        do {
            let _: Int = try await CancellableNFCRequest.run { throw NSError(domain: "test-nfc", code: 102) }
            XCTFail("Error ignored")
        } catch { XCTAssertEqual((error as NSError).domain, "test-nfc") }
    }
}
