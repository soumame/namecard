import XCTest
import UIKit
import NamecardCore
@testable import Namecard

@MainActor
final class EditorTests: XCTestCase {
    func testContinuousTransformIsOneUndoAndKeepsRawMovementAcrossSnap() {
        let model = EditorModel()
        model.addText("名刺")
        let original = model.layers[0]
        model.snapEnabled = true
        model.beginTransform()
        model.transformSelection(pan: CGPoint(x: 2, y: 0), zoom: 1.1, rotation: 0.1)
        XCTAssertEqual(model.layers[0].center.x, 148)
        model.transformSelection(pan: CGPoint(x: 5, y: 0), zoom: 1.1, rotation: 0.1)
        model.endTransform()
        XCTAssertEqual(model.layers[0].center.x, 155)
        XCTAssertEqual(model.layers[0].rotation, 0.2, accuracy: 0.0001)
        model.undo()
        XCTAssertEqual(model.layers[0].center, original.center)
        XCTAssertEqual(model.layers[0].fontSize, original.fontSize)
        XCTAssertEqual(model.layers[0].rotation, original.rotation)
        model.redo()
        XCTAssertEqual(model.layers[0].center.x, 155)
        XCTAssertFalse(model.canRedo)
    }

    func testUndoBoundAndNewEditInvalidatesRedo() {
        let model = EditorModel()
        for value in 0..<55 { model.addText("\(value)") }
        for _ in 0..<50 { model.undo() }
        XCTAssertEqual(model.layers.count, 5)
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.canRedo)
        model.addText("新しい要素")
        XCTAssertFalse(model.canRedo)
    }

    func testLayerOrderDeleteAndClearAreReversible() {
        let model = EditorModel()
        model.addText("奥")
        let behind = model.selection
        model.addText("前")
        let front = model.selection
        model.moveBackward()
        XCTAssertEqual(model.layers.first?.id, front)
        model.select(at: CGPoint(x: 148, y: 64))
        XCTAssertEqual(model.selection, behind)
        model.deleteSelection()
        XCTAssertEqual(model.layers.count, 1)
        model.undo()
        XCTAssertEqual(model.layers.count, 2)
        model.clear()
        XCTAssertTrue(model.layers.isEmpty)
        model.undo()
        XCTAssertEqual(model.layers.count, 2)
    }

    func testDecorationsAndViewportNeverChangeExport() throws {
        let model = EditorModel()
        model.addText("日本語の名刺")
        model.adjustSelection(pan: CGPoint(x: -45, y: -20), rotation: 0.2)
        let original = try model.renderNativeImage()
        model.gridEnabled = true
        model.snapEnabled = true
        model.viewport.apply(pan: CGPoint(x: 40, y: -30), zoom: 2.4, rotation: 0.8,
                             focus: CGPoint(x: 100, y: 150), size: CGSize(width: 393, height: 400))
        model.deselect()
        XCTAssertEqual(try model.renderNativeImage(), original)
        model.resetViewport()
        XCTAssertTrue(model.viewport.isDefault)
        XCTAssertEqual(try model.renderNativeImage(), original)
    }

    func testBINRoundTripPreservesNativeAxesAndBothFormats() throws {
        var argb = [UInt32](repeating: 0xffffffff, count: 296 * 128)
        // Asymmetric corners catch horizontal/vertical inversion in Core Graphics bridges.
        argb[0] = 0xff000000
        argb[4 * 296 + 20] = 0xff555555
        argb[119 * 296 + 280] = 0xffaaaaaa
        argb[127 * 296 + 295] = 0xff000000
        for format in ImageFormat.allCases {
            let data = try NativeImage.encode(argb: argb, format: format)
            let model = EditorModel()
            try model.load(data: data, format: format)
            XCTAssertEqual(model.layers.count, 1)
            XCTAssertEqual(model.format, format)
            XCTAssertEqual(try model.renderNativeImage(), data)
        }
    }

    func testBlankCanvasIsWhiteAndRejectsInvalidImage() throws {
        let model = EditorModel()
        XCTAssertEqual(try model.renderNativeImage(), Data(repeating: 0xff, count: 4_736))
        model.format = .gray4
        XCTAssertEqual(try model.renderNativeImage(), Data(repeating: 0, count: 9_472))
        XCTAssertThrowsError(try model.addImage(data: Data([0, 1, 2])))
        XCTAssertThrowsError(try model.load(data: Data(repeating: 0, count: 42), format: .dotDensity))
        XCTAssertFalse(model.hasContent)
    }

    func testImportedImageKeepsAlphaAndNormalizesOrientationAndSize() throws {
        let config = UIGraphicsImageRendererFormat()
        config.scale = 1
        config.opaque = false
        config.preferredRange = .standard
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1200), format: config).image { _ in
            UIColor.black.withAlphaComponent(0.5).setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
        }
        let oriented = UIImage(cgImage: try XCTUnwrap(source.cgImage), scale: 1, orientation: .right)
        let normalized = try EditorModel.normalizedImage(oriented)
        XCTAssertEqual(normalized.imageOrientation, .up)
        XCTAssertEqual(max(normalized.size.width, normalized.size.height), 2048)
        XCTAssertEqual(normalized.size.width / normalized.size.height, oriented.size.width / oriented.size.height,
                       accuracy: 0.001)
        let model = EditorModel()
        model.format = .gray4
        try model.addImage(oriented)
        let decoded = try NativeImage.decode(model.renderNativeImage(), format: .gray4)
        let center = decoded[64 * 296 + 148]
        XCTAssertTrue([UInt32(0xff555555), UInt32(0xffaaaaaa)].contains(center),
                      "Half-transparent black must composite on white, not become opaque black")
        XCTAssertEqual(decoded[0], 0xffffffff)
    }

    func testGridThresholdTieAndViewportInverse() {
        XCTAssertEqual(EditorModel.gridCoordinate(151, origin: 148), 148)
        XCTAssertEqual(EditorModel.gridCoordinate(153, origin: 148), 156)
        XCTAssertEqual(EditorModel.closestSnap(144, candidates: [148, 140]), 0)
        XCTAssertNil(EditorModel.closestSnap(10, candidates: [0, 20]))
        var viewport = EditorViewport()
        let size = CGSize(width: 390, height: 500)
        viewport.apply(pan: CGPoint(x: 80, y: -50), zoom: 3, rotation: 0.7,
                       focus: CGPoint(x: 42, y: 320), size: size)
        let transform = viewport.transform(in: size)
        for point in [CGPoint.zero, CGPoint(x: 148, y: 64), CGPoint(x: 296, y: 128)] {
            let recovered = point.applying(transform).applying(transform.inverted())
            XCTAssertEqual(recovered.x, point.x, accuracy: 0.0001)
            XCTAssertEqual(recovered.y, point.y, accuracy: 0.0001)
        }
        viewport.apply(pan: .zero, zoom: 100, rotation: 0, focus: .zero, size: size)
        XCTAssertEqual(viewport.scale, 5)
        viewport.apply(pan: .zero, zoom: 0.001, rotation: 0, focus: .zero, size: size)
        XCTAssertEqual(viewport.scale, 0.5)
    }
}
