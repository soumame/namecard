import XCTest
import UIKit
import CoreImage
import NamecardCore
@testable import Namecard

@MainActor
final class QRCodeTests: XCTestCase {
    func testPreviewAndCanvasImagesDecodeToNormalizedURL() throws {
        for input in ["example.com", "https://example.com/名刺?a=1&b=2", "http://example.com/a%2F#test"] {
            let code = try QRCode.generate(input)
            XCTAssertTrue(code.canAddToCanvas)
            for scale in [code.canvasScale, code.previewScale] {
                let image = try code.image(scale: scale)
                XCTAssertEqual(try decode(image), try URLCodec.normalize(input))
                let png = try XCTUnwrap(image.pngData())
                XCTAssertEqual(try decode(XCTUnwrap(UIImage(data: png))), code.url)
            }
        }
    }

    func testAddedCodeSurvivesNativeBINAndUndoRedo() throws {
        let code = try QRCode.generate("https://example.com/namecard")
        let model = EditorModel()
        model.addText("既存の要素")
        try model.addQRCode(code)
        XCTAssertEqual(model.layers.count, 2)
        let qr = try XCTUnwrap(model.layers.last)
        XCTAssertTrue(qr.pixelated)
        XCTAssertLessThanOrEqual(qr.size.height, 120)
        XCTAssertEqual(qr.bounds.minX, floor(qr.bounds.minX))
        XCTAssertEqual(qr.bounds.minY, floor(qr.bounds.minY))
        for format in ImageFormat.allCases {
            model.format = format
            let bytes = try model.renderNativeImage()
            XCTAssertEqual(try decode(EditorModel.image(data: bytes, format: format)), code.url)
        }
        model.undo()
        XCTAssertEqual(model.layers.count, 1)
        model.redo()
        XCTAssertEqual(model.layers.last?.id, qr.id)
        XCTAssertTrue(model.layers.last?.pixelated == true)
    }

    func testDenseCodeIsNotAddedAtUnreadableSize() throws {
        let code = try QRCode.generate("https://example.com/" + String(repeating: "x", count: 600))
        XCTAssertFalse(code.canAddToCanvas)
        XCTAssertEqual(try decode(code.image(scale: code.previewScale)), code.url)
        let model = EditorModel()
        XCTAssertThrowsError(try model.addQRCode(code))
        XCTAssertFalse(model.hasContent)
        XCTAssertFalse(model.canUndo)
    }

    func testInvalidAndExcessivelyLongURLsAreRejected() {
        for input in ["", " \n", "mailto:a@example.com", "https://example.com/a b", "https://example.com/" + String(repeating: "x", count: 2000)] {
            XCTAssertThrowsError(try QRCode.generate(input), input)
        }
    }

    private func decode(_ image: UIImage) throws -> String? {
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode, context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let input = CIImage(cgImage: try XCTUnwrap(image.cgImage))
        return (detector.features(in: input).first as? CIQRCodeFeature)?.messageString
    }
}
