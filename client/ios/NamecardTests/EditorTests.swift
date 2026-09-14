import XCTest
import UIKit
import NamecardCore
@testable import Namecard

@MainActor
final class EditorTests: XCTestCase {
    func testTextStyleChangesRenderingAndSurvivesTransformUndoRedo() throws {
        let model = EditorModel()
        let style = EditorTextStyle(fontFamily: "Helvetica Neue", bold: false, italic: true, underline: true)
        model.addText("Namecard 日本語", style: style)
        let original = model.layers[0]
        let image = try model.renderNativeImage()
        model.adjustSelection(zoom: 1.3, rotation: 0.2)
        XCTAssertEqual(model.layers[0].textStyle, style)
        model.undo()
        XCTAssertEqual(model.layers[0].fontSize, original.fontSize)
        XCTAssertEqual(model.layers[0].textStyle, style)
        XCTAssertEqual(try model.renderNativeImage(), image)
        model.undo()
        XCTAssertTrue(model.layers.isEmpty)
        model.redo()
        XCTAssertEqual(model.layers[0].textStyle, style)
        XCTAssertEqual(try model.renderNativeImage(), image)
    }

    func testEachTextStyleAffectsBothBINFormats() throws {
        for format in ImageFormat.allCases {
            let regular = EditorModel()
            regular.format = format
            regular.addText("Namecard 日本語", style: EditorTextStyle(bold: false))
            let baseline = try regular.renderNativeImage()
            for style in [EditorTextStyle(), EditorTextStyle(bold: false, italic: true),
                          EditorTextStyle(bold: false, underline: true),
                          EditorTextStyle(fontFamily: "Courier", bold: false)] {
                let styled = EditorModel()
                styled.format = format
                styled.addText("Namecard 日本語", style: style)
                XCTAssertNotEqual(try styled.renderNativeImage(), baseline)
                XCTAssertTrue(styled.layers[0].bounds.contains(styled.layers[0].textDrawingBounds))
            }
        }
    }

    func testJapaneseFamilyWithoutItalicFaceStillRendersItalic() throws {
        let family = try XCTUnwrap(EditorTextStyle.availableFontFamilies.first { $0 == "Hiragino Sans" })
        let regularStyle = EditorTextStyle(fontFamily: family, bold: false)
        let italicStyle = EditorTextStyle(fontFamily: family, bold: false, italic: true)
        XCTAssertEqual(italicStyle.font(at: 24).familyName, family)
        let regular = EditorModel()
        regular.addText("日本語の名刺", style: regularStyle)
        let italic = EditorModel()
        italic.addText("日本語の名刺", style: italicStyle)
        XCTAssertNotEqual(try italic.renderNativeImage(), try regular.renderNativeImage())

        let systemRegular = EditorModel()
        systemRegular.addText("日本語の名刺", style: EditorTextStyle(bold: false))
        let systemItalic = EditorModel()
        systemItalic.addText("日本語の名刺", style: EditorTextStyle(bold: false, italic: true))
        XCTAssertNotEqual(try systemItalic.renderNativeImage(), try systemRegular.renderNativeImage(),
                          "Italic must apply to Japanese fallback glyphs as well as Latin glyphs")
    }

    func testDefaultTextRemainsSystemBoldAndMissingFamilyFallsBack() {
        let model = EditorModel()
        model.addText("名刺")
        XCTAssertEqual(model.layers[0].textStyle, EditorTextStyle())
        XCTAssertEqual(model.layers[0].textStyle.font(at: 24), UIFont.systemFont(ofSize: 24, weight: .bold))
        let missing = EditorTextStyle(fontFamily: "Missing Namecard Font", italic: true, underline: true)
        XCTAssertTrue(missing.font(at: 24).fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertEqual(missing.attributes(at: 24)[.obliqueness] as? Double, 0.2)
        XCTAssertEqual(missing.attributes(at: 24)[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
    }

    func testStyledInkStaysInsideSelectionBounds() throws {
        for family in [nil, "Hiragino Sans", "Courier", "Times New Roman"] as [String?] {
            for zoom in [CGFloat(1), 4] {
                let model = EditorModel()
                model.addText(zoom == 1 ? "fjÁg日本語" : "f日", style: EditorTextStyle(fontFamily: family, italic: true, underline: true))
                model.adjustSelection(zoom: sqrt(zoom))
                model.adjustSelection(zoom: sqrt(zoom))
                let bounds = model.layers[0].bounds.insetBy(dx: -1, dy: -1)
                let pixels = try NativeImage.decode(model.renderNativeImage(), format: .dotDensity)
                let outside = pixels.indices.filter { pixels[$0] != 0xffffffff }.filter {
                    !bounds.contains(CGPoint(x: CGFloat($0 % 296) + 0.5, y: CGFloat($0 / 296) + 0.5))
                }
                let xs = outside.map { $0 % 296 }
                let ys = outside.map { $0 / 296 }
                XCTAssertTrue(outside.isEmpty, "\(family ?? "System") at \(24 * zoom) pt has \(outside.count) ink pixels outside \(bounds): x \(xs.min() ?? 0)...\(xs.max() ?? 0), y \(ys.min() ?? 0)...\(ys.max() ?? 0), \(model.layers[0].textStyle.font(at: 24 * zoom))")
            }
        }
    }

    func testViewportSnapAccumulatesSmallDeltasAndKeepsGestureFocusAnchored() {
        var viewport = EditorViewport()
        let size = CGSize(width: 390, height: 500)
        let focus = CGPoint(x: 42, y: 320)
        let paperFocus = focus.applying(viewport.transform(in: size).inverted())
        viewport.beginTransform()
        for angle in 1...5 {
            viewport.apply(pan: .zero, zoom: 1, rotation: .pi / 180, focus: focus, size: size,
                           rotationSnapEnabled: true)
            XCTAssertEqual(viewport.rotation, angle <= 4 ? 0 : 5 * .pi / 180, accuracy: 0.00001)
            let anchored = paperFocus.applying(viewport.transform(in: size))
            XCTAssertEqual(anchored.x, focus.x, accuracy: 0.0001)
            XCTAssertEqual(anchored.y, focus.y, accuracy: 0.0001)
        }
        viewport.apply(pan: CGPoint(x: 10, y: -8), zoom: 1.4, rotation: 7 * .pi / 180,
                       focus: focus, size: size, rotationSnapEnabled: true)
        XCTAssertEqual(viewport.rotation, 15 * .pi / 180, accuracy: 0.00001)
        let movedFocus = paperFocus.applying(viewport.transform(in: size))
        XCTAssertEqual(movedFocus.x, focus.x + 10, accuracy: 0.0001)
        XCTAssertEqual(movedFocus.y, focus.y - 8, accuracy: 0.0001)
        viewport.endTransform()
        viewport.beginTransform()
        viewport.apply(pan: .zero, zoom: 1, rotation: .pi / 180, focus: focus, size: size,
                       rotationSnapEnabled: true)
        XCTAssertEqual(viewport.rotation, 15 * .pi / 180, accuracy: 0.00001)
    }

    func testViewportSnapHandlesWrapThresholdAndReset() {
        let radians = CGFloat.pi / 180
        XCTAssertEqual(EditorRotationSnap.snapped(179 * radians), -.pi, accuracy: 0.00001)
        XCTAssertEqual(EditorRotationSnap.snapped(-179 * radians), -.pi, accuracy: 0.00001)
        XCTAssertEqual(EditorRotationSnap.snapped(11 * radians), 15 * radians, accuracy: 0.00001)
        XCTAssertEqual(EditorRotationSnap.snapped(-11 * radians), -15 * radians, accuracy: 0.00001)
        XCTAssertEqual(EditorRotationSnap.snapped(10 * radians), 10 * radians, accuracy: 0.00001)
        let model = EditorModel()
        XCTAssertFalse(model.viewportRotationSnapEnabled)
        model.viewportRotationSnapEnabled = true
        XCTAssertFalse(model.snapEnabled)
        model.viewport.beginTransform()
        model.viewport.apply(pan: .zero, zoom: 1, rotation: 3 * radians, focus: .zero,
                             size: CGSize(width: 390, height: 500), rotationSnapEnabled: true)
        XCTAssertEqual(model.viewport.rotation, 0)
        model.viewportRotationSnapEnabled = false
        model.viewport.apply(pan: .zero, zoom: 1, rotation: radians, focus: .zero,
                             size: CGSize(width: 390, height: 500))
        XCTAssertEqual(model.viewport.rotation, radians, accuracy: 0.00001)
        model.resetViewport()
        XCTAssertTrue(model.viewport.isDefault)
        XCTAssertFalse(model.canUndo)
    }

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

    func testObjectRotationSnapAccumulatesForTextAndImagesAndSupportsUndo() throws {
        for imageLayer in [false, true] {
            let model = EditorModel()
            if imageLayer {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 12)).image { context in
                    UIColor.black.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 24, height: 12))
                }
                try model.addImage(image)
            } else {
                model.addText("Snap")
            }
            let original = try model.renderNativeImage()
            XCTAssertFalse(model.objectRotationSnapEnabled)
            model.objectRotationSnapEnabled = true
            XCTAssertFalse(model.snapEnabled)
            XCTAssertFalse(model.viewportRotationSnapEnabled)
            model.beginTransform()
            for _ in 0..<4 {
                model.transformSelection(pan: .zero, zoom: 1, rotation: .pi / 180)
            }
            XCTAssertEqual(model.layers[0].rotation, 0, accuracy: 0.00001)
            model.transformSelection(pan: .zero, zoom: 1, rotation: .pi / 180)
            XCTAssertEqual(model.layers[0].rotation, 5 * .pi / 180, accuracy: 0.00001)
            model.transformSelection(pan: CGPoint(x: 2, y: -3), zoom: 1.2, rotation: 7 * .pi / 180)
            model.endTransform()
            XCTAssertEqual(model.layers[0].rotation, .pi / 12, accuracy: 0.00001)
            XCTAssertEqual(model.layers[0].center, CGPoint(x: 150, y: 61))
            XCTAssertTrue(model.viewport.isDefault)
            let rotated = try model.renderNativeImage()
            XCTAssertNotEqual(rotated, original)
            model.undo()
            XCTAssertEqual(try model.renderNativeImage(), original)
            model.redo()
            XCTAssertEqual(try model.renderNativeImage(), rotated)
            model.beginTransform()
            model.transformSelection(pan: .zero, zoom: 1, rotation: 5 * .pi / 180)
            XCTAssertEqual(model.layers[0].rotation, 20 * .pi / 180, accuracy: 0.00001)
            model.endTransform()
        }
    }

    func testObjectRotationSnapToggleResetsRawAngleAndWrapsWithoutAffectingOtherLayers() {
        let model = EditorModel()
        model.addText("First")
        model.adjustSelection(rotation: 28 * .pi / 180)
        model.objectRotationSnapEnabled = true
        XCTAssertEqual(model.layers[0].rotation, 28 * .pi / 180, accuracy: 0.00001)
        model.beginTransform()
        model.transformSelection(pan: CGPoint(x: -50, y: 0), zoom: 1, rotation: 0)
        XCTAssertEqual(model.layers[0].rotation, 28 * .pi / 180, accuracy: 0.00001)
        model.transformSelection(pan: .zero, zoom: 1, rotation: .pi / 180)
        XCTAssertEqual(model.layers[0].rotation, .pi / 6, accuracy: 0.00001)
        model.objectRotationSnapEnabled = false
        model.transformSelection(pan: .zero, zoom: 1, rotation: .pi / 180)
        XCTAssertEqual(model.layers[0].rotation, 31 * .pi / 180, accuracy: 0.00001)
        model.endTransform()
        model.addText("Second")
        model.adjustSelection(rotation: 178 * .pi / 180)
        model.objectRotationSnapEnabled = true
        model.adjustSelection(rotation: .pi / 180)
        XCTAssertEqual(model.layers[1].rotation, -.pi, accuracy: 0.00001)
        XCTAssertEqual(model.layers[0].rotation, 31 * .pi / 180, accuracy: 0.00001)
        model.undo()
        XCTAssertEqual(model.layers[1].rotation, 178 * .pi / 180, accuracy: 0.00001)
        model.redo()
        model.adjustSelection(rotation: -5 * .pi / 180)
        XCTAssertEqual(model.layers[1].rotation, 175 * .pi / 180, accuracy: 0.00001)
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
        model.viewportRotationSnapEnabled = true
        model.viewport.apply(pan: CGPoint(x: 40, y: -30), zoom: 2.4, rotation: 0.8,
                             focus: CGPoint(x: 100, y: 150), size: CGSize(width: 393, height: 400),
                             rotationSnapEnabled: model.viewportRotationSnapEnabled)
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
