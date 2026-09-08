import CoreNFC
import NamecardCore
import XCTest
@testable import Namecard

final class ST25TransportErrorTests: XCTestCase {
    private func mapped(_ code: Int, iso: Int? = nil, domain: String = NFCErrorDomain) -> Error {
        let info: [String: Any] = iso.map { [NFCISO15693TagResponseErrorKey: NSNumber(value: $0)] } ?? [:]
        return ST25Mailbox.transportError(NSError(domain: domain, code: code, userInfo: info), command: 0xaa)
    }

    func testConnectionLossRequiresNewTagInsteadOfRawCommandRetry() {
        for code in [100, 104] {
            guard case MailboxTransportError.connectionLost = mapped(code) else { return XCTFail("code \(code)") }
            XCTAssertTrue(mapped(code).localizedDescription.contains("ST25 AA"))
            XCTAssertTrue(mapped(code).localizedDescription.contains("\(code)"))
        }
    }

    func testOnlyTransientRFErrorsAreMarkedForDataRetry() {
        for error in [mapped(101), mapped(102), mapped(102, iso: 0x0f)] {
            guard case MailboxTransportError.transient = error else { return XCTFail() }
        }
        for error in [mapped(102, iso: 1), mapped(102, iso: 0x10), mapped(102, iso: 0x12),
                      mapped(103), mapped(105), mapped(200), mapped(201), mapped(2),
                      mapped(101, domain: "unrelated")] {
            XCTAssertFalse(error is MailboxTransportError)
        }
    }

    func testCancellationAndMailboxConfigurationErrorsStayTerminal() {
        XCTAssertTrue(ST25Mailbox.transportError(CancellationError(), command: 0xaa) is CancellationError)
        let source = NSError(domain: NFCErrorDomain, code: 102,
                             userInfo: [NFCISO15693TagResponseErrorKey: NSNumber(value: 0x10)])
        let error = ST25Mailbox.transportError(source, command: 0xad)
        XCTAssertFalse(error is MailboxTransportError)
        XCTAssertTrue(error.localizedDescription.contains("MB_MODE"))
        XCTAssertTrue(error.localizedDescription.contains("ISO15693=10"))
    }
}
