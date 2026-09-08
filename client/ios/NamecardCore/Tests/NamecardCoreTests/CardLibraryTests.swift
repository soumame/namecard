import Foundation
import XCTest
@testable import NamecardCore

final class CardLibraryTests: XCTestCase {
    func testSaveReopenRenameAndDeleteBothFormats() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try CardLibrary(directoryURL: directory)
        let first = try library.save(name: " 名刺 ", format: .dotDensity, bytes: Data(repeating: 255, count: 4_736))
        let second = try library.save(name: " ", format: .gray4, bytes: Data(repeating: 0, count: 9_472))
        let reopened = try CardLibrary(directoryURL: directory)
        XCTAssertEqual(try reopened.list().count, 2)
        XCTAssertEqual(try reopened.list().first?.id, second.id)
        XCTAssertEqual(first.name, "名刺")
        XCTAssertEqual(second.name, "名称未設定")
        let renamed = try reopened.rename(id: first.id, name: String(repeating: "名", count: 100))
        XCTAssertEqual(renamed.name.count, 80)
        XCTAssertEqual(renamed.createdAt, first.createdAt)
        XCTAssertEqual(renamed.bytes, first.bytes)
        try reopened.delete(id: second.id)
        try reopened.delete(id: second.id)
        XCTAssertEqual(try reopened.list(), [renamed])
    }

    func testInvalidAndInterruptedFilesAreNotListed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try CardLibrary(directoryURL: directory)
        XCTAssertThrowsError(try library.save(name: "bad", format: .gray4, bytes: Data(repeating: 0, count: 4_736)))
        let card = try library.save(name: "valid", format: .dotDensity, bytes: Data(repeating: 0, count: 4_736))
        try Data("invalid json".utf8).write(to: directory.appendingPathComponent(UUID().uuidString + ".json"))
        try Data(repeating: 0, count: 4_736).write(to: directory.appendingPathComponent("orphan.bin"))
        XCTAssertEqual(try library.list(), [card])
        try Data([0]).write(to: directory.appendingPathComponent(card.id.uuidString + ".bin"))
        XCTAssertEqual(try library.list(), [])
    }
}
