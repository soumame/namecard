import NamecardCore
import UIKit
import XCTest
@testable import Namecard

@MainActor
final class LibraryThumbnailTests: XCTestCase {
    func testReloadAndRenameReuseThumbnailsWithoutDecodingAgain() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory)
        let bytes = Data(repeating: 0xff, count: ImageFormat.dotDensity.byteCount)
        model.save(bytes, format: .dotDensity, name: "最初の名前")
        let card = try XCTUnwrap(model.cards.first)
        let original = try XCTUnwrap(model.thumbnail(for: card))

        for _ in 0..<5 {
            XCTAssertTrue(model.thumbnail(for: card) === original, "画面更新からの参照で再生成しない")
            model.reload()
            XCTAssertTrue(model.thumbnail(for: card) === original)
        }
        model.rename(card, to: "変更した名前")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.cards.first?.name, "変更した名前")
        XCTAssertEqual(model.cards.first?.bytes, bytes)
        XCTAssertTrue(model.thumbnail(for: card) === original, "名称だけの変更では画像を再生成しない")
    }

    func testChangedBINWithSameIDReplacesThumbnail() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory)
        model.save(Data(repeating: 0xff, count: 4_736), format: .dotDensity, name: "変更テスト")
        let card = try XCTUnwrap(model.cards.first)
        let original = try XCTUnwrap(model.thumbnail(for: card))
        let replacement = Data(repeating: 0, count: 4_736)
        let file = directory.appendingPathComponent("card-library").appendingPathComponent("\(card.id.uuidString).bin")
        try replacement.write(to: file, options: .atomic)

        model.reload()
        let updated = try XCTUnwrap(model.thumbnail(for: card))
        XCTAssertFalse(updated === original)
        XCTAssertEqual(model.cards.first?.bytes, replacement)
        XCTAssertEqual(updated.pngData(), try EditorModel.image(data: replacement, format: .dotDensity).pngData())

        // A corrupt file disappears from the Library and must not leave a cached preview.
        try Data([0]).write(to: file, options: .atomic)
        model.reload()
        XCTAssertTrue(model.cards.isEmpty)
        XCTAssertNil(model.thumbnail(for: card))
    }

    func testBothFormatsSurviveReopenAndDeletionDropsOnlyRemovedThumbnail() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory)
        var pixels = [UInt32](repeating: 0xffffffff, count: 296 * 128)
        pixels[0] = 0xff000000
        pixels[8 * 296 + 20] = 0xff555555
        pixels[120 * 296 + 280] = 0xffaaaaaa
        for format in ImageFormat.allCases {
            let bytes = try NativeImage.encode(argb: pixels, format: format)
            model.save(bytes, format: format, name: format.title)
            let card = try XCTUnwrap(model.cards.first { $0.format == format })
            let image = try XCTUnwrap(model.thumbnail(for: card))
            XCTAssertEqual(image.cgImage?.width, 296)
            XCTAssertEqual(image.cgImage?.height, 128)
            XCTAssertEqual(image.pngData(), try EditorModel.image(data: bytes, format: format).pngData())
            XCTAssertEqual(card.bytes, bytes)
        }

        let reopened = AppModel(directory: directory)
        XCTAssertEqual(reopened.cards, model.cards)
        for card in reopened.cards {
            XCTAssertEqual(reopened.thumbnail(for: card)?.pngData(), model.thumbnail(for: card)?.pngData())
        }
        let removed = try XCTUnwrap(reopened.cards.first { $0.format == .dotDensity })
        let kept = try XCTUnwrap(reopened.cards.first { $0.format == .gray4 })
        let keptImage = try XCTUnwrap(reopened.thumbnail(for: kept))
        reopened.delete(removed)
        XCTAssertNil(reopened.errorMessage)
        XCTAssertNil(reopened.thumbnail(for: removed))
        XCTAssertTrue(reopened.thumbnail(for: kept) === keptImage)
        XCTAssertEqual(reopened.cards.map(\.id), [kept.id])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LibraryThumbnailTests-\(UUID().uuidString)")
    }
}
