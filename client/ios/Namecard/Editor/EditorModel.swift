import Foundation
import Observation
import UIKit
import NamecardCore

enum EditorError: LocalizedError {
    case unreadableImage
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "画像を読み込めません。JPEG・PNG・WebPの画像を選択してください。"
        case .renderingFailed: "画像を作成できませんでした。"
        }
    }
}

struct EditorLayer: Identifiable {
    enum Content { case text(String), image(UIImage) }

    let id: UUID
    var content: Content
    var center = CGPoint(x: 148, y: 64)
    var size: CGSize
    var fontSize: CGFloat = 24
    var rotation: CGFloat = 0
    var pixelated = false

    @MainActor var bounds: CGRect {
        let measured: CGSize
        switch content {
        case .text(let text):
            measured = (text as NSString).size(withAttributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .bold)
            ])
        case .image: measured = size
        }
        return CGRect(x: center.x - measured.width / 2, y: center.y - measured.height / 2,
                      width: measured.width, height: measured.height)
    }

    @MainActor func contains(_ point: CGPoint) -> Bool {
        let delta = CGPoint(x: point.x - center.x, y: point.y - center.y).rotated(-rotation)
        return bounds.insetBy(dx: -5, dy: -5).contains(
            CGPoint(x: delta.x + center.x, y: delta.y + center.y)
        )
    }

    mutating func resize(_ factor: CGFloat) {
        let safe = factor.clamped(to: 0.5...2)
        switch content {
        case .text:
            fontSize = (fontSize * safe).clamped(to: 6...96)
        case .image:
            let lower = 2 / max(size.width, size.height)
            let upper = min(592 / size.width, 256 / size.height)
            let applied = safe.clamped(to: lower...max(lower, upper))
            size = CGSize(width: size.width * applied, height: size.height * applied)
        }
    }
}

struct EditorViewport {
    var scale: CGFloat = 1
    var offset: CGPoint = .zero
    var rotation: CGFloat = 0

    var isDefault: Bool {
        abs(scale - 1) < 0.001 && abs(offset.x) < 0.5 && abs(offset.y) < 0.5 && abs(rotation) < 0.001
    }

    func transform(in size: CGSize) -> CGAffineTransform {
        let fit = max(0.01, min((size.width - 32) / 296, (size.height - 32) / 128))
        return CGAffineTransform(translationX: size.width / 2 + offset.x, y: size.height / 2 + offset.y)
            .rotated(by: rotation).scaledBy(x: fit * scale, y: fit * scale)
            .translatedBy(x: -148, y: -64)
    }

    mutating func apply(pan: CGPoint, zoom: CGFloat, rotation delta: CGFloat, focus: CGPoint, size: CGSize) {
        guard zoom.isFinite, zoom > 0, delta.isFinite else { return }
        let next = (scale * zoom).clamped(to: 0.5...5)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let relative = CGPoint(x: center.x + offset.x - focus.x, y: center.y + offset.y - focus.y)
            .rotated(delta)
        offset = CGPoint(x: focus.x + relative.x * next / scale + pan.x - center.x,
                         y: focus.y + relative.y * next / scale + pan.y - center.y)
        scale = next
        rotation = (rotation + delta).normalizedAngle
    }
}

@MainActor @Observable
final class EditorModel {
    static let paper = CGRect(x: 0, y: 0, width: 296, height: 128)
    var format: ImageFormat = .dotDensity
    private(set) var layers: [EditorLayer] = []
    private(set) var selection: UUID?
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var revision = 0
    var gridEnabled = false { didSet { changed() } }
    var snapEnabled = false { didSet { snapGuideX = nil; snapGuideY = nil; changed() } }
    var viewport = EditorViewport() { didSet { changed() } }
    private(set) var snapGuideX: CGFloat?
    private(set) var snapGuideY: CGFloat?

    @ObservationIgnored private var undoStack: [Snapshot] = []
    @ObservationIgnored private var redoStack: [Snapshot] = []
    @ObservationIgnored private var transformStart: Snapshot?
    @ObservationIgnored private var rawCenter: CGPoint?
    @ObservationIgnored private var transformRecorded = false

    var hasSelection: Bool { selectedIndex != nil }
    var hasContent: Bool { !layers.isEmpty }
    var canMoveForward: Bool { selectedIndex.map { $0 < layers.count - 1 } ?? false }
    var canMoveBackward: Bool { selectedIndex.map { $0 > 0 } ?? false }
    private var selectedIndex: Int? { layers.firstIndex { $0.id == selection } }

    func addText(_ value: String) {
        let trace = PerformanceTrace.begin("Editor.addText")
        defer { PerformanceTrace.end(trace) }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        recordChange()
        let layer = EditorLayer(id: UUID(), content: .text(text), size: .zero)
        layers.append(layer)
        selection = layer.id
        changed()
    }

    func addImage(data: Data) throws {
        guard let image = UIImage(data: data) else { throw EditorError.unreadableImage }
        try addImage(image)
    }

    func addImage(_ source: UIImage) throws {
        let image = try Self.normalizedImage(source)
        let fit = min(1, 296 * 0.55 / image.size.width, 128 * 0.70 / image.size.height)
        recordChange()
        let layer = EditorLayer(id: UUID(), content: .image(image),
                                size: CGSize(width: image.size.width * fit, height: image.size.height * fit))
        layers.append(layer)
        selection = layer.id
        changed()
    }

    func addQRCode(_ code: QRCode) throws {
        guard code.canAddToCanvas else { throw QRCodeError.tooLong }
        let image = try code.image(scale: code.canvasScale)
        let side = image.size.width
        recordChange()
        let layer = EditorLayer(
            id: UUID(), content: .image(image),
            center: CGPoint(x: floor((296 - side) / 2) + side / 2, y: floor((128 - side) / 2) + side / 2),
            size: image.size, pixelated: true
        )
        layers.append(layer)
        selection = layer.id
        changed()
    }

    func load(data: Data, format: ImageFormat) throws {
        let image = try Self.image(data: data, format: format)
        recordChange()
        let layer = EditorLayer(id: UUID(), content: .image(image), size: Self.paper.size)
        layers = [layer]
        selection = layer.id
        self.format = format
        viewport = EditorViewport()
        changed()
    }

    func select(at point: CGPoint) {
        selection = layers.last(where: { $0.contains(point) })?.id
        changed()
    }

    func deselect() { selection = nil; changed() }

    func beginTransform() {
        guard let index = selectedIndex else { return }
        transformStart = snapshot()
        transformRecorded = false
        rawCenter = layers[index].center
        snapGuideX = nil
        snapGuideY = nil
    }

    func transformSelection(pan: CGPoint, zoom: CGFloat, rotation: CGFloat) {
        guard let index = selectedIndex, pan.x.isFinite, pan.y.isFinite,
              zoom.isFinite, zoom > 0, rotation.isFinite else { return }
        guard pan != .zero || abs(zoom - 1) > 0.001 || abs(rotation) > 0.0001 else { return }
        if !transformRecorded {
            pushUndo(transformStart ?? snapshot())
            transformRecorded = true
        }
        let previous = rawCenter ?? layers[index].center
        let raw = CGPoint(x: (previous.x + pan.x).clamped(to: 0...296),
                          y: (previous.y + pan.y).clamped(to: 0...128))
        rawCenter = raw
        layers[index].resize(zoom)
        layers[index].rotation = (layers[index].rotation + rotation).normalizedAngle
        layers[index].center = snapEnabled ? snapped(raw, index: index) : raw
        changed()
    }

    func endTransform() {
        transformStart = nil
        transformRecorded = false
        rawCenter = nil
        snapGuideX = nil
        snapGuideY = nil
        changed()
    }

    func adjustSelection(pan: CGPoint = .zero, zoom: CGFloat = 1, rotation: CGFloat = 0) {
        beginTransform()
        transformSelection(pan: pan, zoom: zoom, rotation: rotation)
        endTransform()
    }

    func moveForward() {
        guard let index = selectedIndex, index < layers.count - 1 else { return }
        recordChange()
        layers.swapAt(index, index + 1)
        changed()
    }

    func moveBackward() {
        guard let index = selectedIndex, index > 0 else { return }
        recordChange()
        layers.swapAt(index, index - 1)
        changed()
    }

    func deleteSelection() {
        guard let index = selectedIndex else { return }
        recordChange()
        layers.remove(at: index)
        selection = layers.isEmpty ? nil : layers[min(index, layers.count - 1)].id
        changed()
    }

    func clear() {
        guard !layers.isEmpty else { return }
        recordChange()
        layers.removeAll()
        selection = nil
        changed()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        if undoStack.count > 50 { undoStack.removeFirst() }
        restore(next)
    }

    func resetViewport() { viewport = EditorViewport() }

    func renderNativeImage() throws -> Data {
        let trace = PerformanceTrace.begin("Editor.renderBIN")
        defer { PerformanceTrace.end(trace) }
        let configuration = UIGraphicsImageRendererFormat()
        configuration.scale = 1
        configuration.opaque = true
        configuration.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: Self.paper.size, format: configuration).image {
            draw(in: $0.cgContext, decorations: false)
        }
        guard let cgImage = image.cgImage else { throw EditorError.renderingFailed }
        return try NativeImage.encode(argb: Self.argb(cgImage), format: format)
    }

    static func image(data: Data, format: ImageFormat) throws -> UIImage {
        let trace = PerformanceTrace.begin("Editor.decodeBIN")
        defer { PerformanceTrace.end(trace) }
        let argb = try NativeImage.decode(data, format: format)
        var rgba = [UInt8]()
        rgba.reserveCapacity(argb.count * 4)
        for color in argb {
            rgba += [UInt8((color >> 16) & 255), UInt8((color >> 8) & 255),
                     UInt8(color & 255), UInt8((color >> 24) & 255)]
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: 296, height: 128, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: 296 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw EditorError.renderingFailed }
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }

    func draw(in context: CGContext, decorations: Bool) {
        let trace = PerformanceTrace.begin("Editor.draw")
        defer { PerformanceTrace.end(trace) }
        context.saveGState()
        context.clip(to: Self.paper)
        context.setFillColor(UIColor.white.cgColor)
        context.fill(Self.paper)
        if decorations && gridEnabled { drawGrid(in: context) }
        UIGraphicsPushContext(context)
        for layer in layers {
            context.saveGState()
            context.translateBy(x: layer.center.x, y: layer.center.y)
            context.rotate(by: layer.rotation)
            context.translateBy(x: -layer.center.x, y: -layer.center.y)
            switch layer.content {
            case .image(let image):
                if layer.pixelated {
                    context.interpolationQuality = .none
                    context.setShouldAntialias(false)
                }
                image.draw(in: layer.bounds)
            case .text(let value):
                (value as NSString).draw(in: layer.bounds, withAttributes: [
                    .font: UIFont.systemFont(ofSize: layer.fontSize, weight: .bold),
                    .foregroundColor: UIColor.black
                ])
            }
            context.restoreGState()
        }
        UIGraphicsPopContext()
        if decorations {
            context.setStrokeColor(UIColor.systemOrange.cgColor)
            context.setLineWidth(1)
            if let x = snapGuideX { line(in: context, from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: 128)) }
            if let y = snapGuideY { line(in: context, from: CGPoint(x: 0, y: y), to: CGPoint(x: 296, y: y)) }
            if let index = selectedIndex {
                let layer = layers[index]
                context.saveGState()
                context.translateBy(x: layer.center.x, y: layer.center.y)
                context.rotate(by: layer.rotation)
                context.translateBy(x: -layer.center.x, y: -layer.center.y)
                context.setStrokeColor(UIColor.systemBlue.cgColor)
                context.setLineWidth(1.2)
                context.setLineDash(phase: 0, lengths: [5, 3])
                context.stroke(layer.bounds.insetBy(dx: -2, dy: -2))
                context.restoreGState()
            }
        }
        context.restoreGState()
    }

    private func snapped(_ point: CGPoint, index: Int) -> CGPoint {
        let layer = layers[index]
        let width = layer.bounds.width
        let height = layer.bounds.height
        let halfWidth = abs(cos(layer.rotation)) * width / 2 + abs(sin(layer.rotation)) * height / 2
        let halfHeight = abs(sin(layer.rotation)) * width / 2 + abs(cos(layer.rotation)) * height / 2
        var xs: [(CGFloat, CGFloat)] = [(148, 148)]
        var ys: [(CGFloat, CGFloat)] = [(64, 64)]
        if halfWidth * 2 <= 296 { xs += [(halfWidth, 0), (296 - halfWidth, 296)] }
        if halfHeight * 2 <= 128 { ys += [(halfHeight, 0), (128 - halfHeight, 128)] }
        for peer in layers where peer.id != layer.id {
            xs.append((peer.center.x, peer.center.x))
            ys.append((peer.center.y, peer.center.y))
        }
        if gridEnabled {
            let gx = Self.gridCoordinate(point.x, origin: 148).clamped(to: 0...296)
            let gy = Self.gridCoordinate(point.y, origin: 64).clamped(to: 0...128)
            xs.append((gx, gx)); ys.append((gy, gy))
        }
        let x = Self.closestSnap(point.x, candidates: xs.map(\.0))
        let y = Self.closestSnap(point.y, candidates: ys.map(\.0))
        snapGuideX = x.map { xs[$0].1 }
        snapGuideY = y.map { ys[$0].1 }
        return CGPoint(x: x.map { xs[$0].0 } ?? point.x, y: y.map { ys[$0].0 } ?? point.y)
    }

    static func closestSnap(_ value: CGFloat, candidates: [CGFloat]) -> Int? {
        candidates.indices.filter { abs(candidates[$0] - value) <= 4 }
            .min { abs(candidates[$0] - value) < abs(candidates[$1] - value) }
    }

    static func gridCoordinate(_ value: CGFloat, origin: CGFloat) -> CGFloat {
        origin + ((value - origin) / 8).rounded(.toNearestOrEven) * 8
    }

    private func drawGrid(in context: CGContext) {
        context.setLineWidth(0.45)
        context.setStrokeColor(UIColor.black.withAlphaComponent(0.2).cgColor)
        for x in stride(from: 4, through: 296, by: 8) {
            line(in: context, from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: 128))
        }
        for y in stride(from: 0, through: 128, by: 8) {
            line(in: context, from: CGPoint(x: 0, y: y), to: CGPoint(x: 296, y: y))
        }
        context.setLineWidth(0.8)
        context.setStrokeColor(UIColor.systemPurple.withAlphaComponent(0.6).cgColor)
        line(in: context, from: CGPoint(x: 148, y: 0), to: CGPoint(x: 148, y: 128))
        line(in: context, from: CGPoint(x: 0, y: 64), to: CGPoint(x: 296, y: 64))
    }

    private func line(in context: CGContext, from start: CGPoint, to end: CGPoint) {
        context.move(to: start); context.addLine(to: end); context.strokePath()
    }

    private struct Snapshot { var layers: [EditorLayer]; var selection: UUID? }
    private func snapshot() -> Snapshot { Snapshot(layers: layers, selection: selection) }
    private func restore(_ value: Snapshot) {
        layers = value.layers; selection = value.selection
        endTransform()
    }
    private func recordChange() { endTransform(); pushUndo(snapshot()) }
    private func pushUndo(_ value: Snapshot) {
        undoStack.append(value)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        changed()
    }
    private func changed() {
        revision &+= 1
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// Correct EXIF orientation before resizing; preserve alpha so overlapping layers composite correctly.
    static func normalizedImage(_ source: UIImage) throws -> UIImage {
        let trace = PerformanceTrace.begin("Editor.normalizeImage")
        defer { PerformanceTrace.end(trace) }
        guard source.size.width > 0, source.size.height > 0 else { throw EditorError.unreadableImage }
        let factor = min(1, 2048 / max(source.size.width * source.scale, source.size.height * source.scale))
        let size = CGSize(width: max(1, (source.size.width * source.scale * factor).rounded()),
                          height: max(1, (source.size.height * source.scale * factor).rounded()))
        let configuration = UIGraphicsImageRendererFormat()
        configuration.scale = 1
        configuration.opaque = false
        configuration.preferredRange = .standard
        let normalized = UIGraphicsImageRenderer(size: size, format: configuration).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let original = normalized.cgImage else { throw EditorError.unreadableImage }
        var pixels = try rgba(original)
        // Android's ColorMatrix.setSaturation(0) uses these weights on premultiplied channels.
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = 213 * Int(pixels[index])
            let green = 715 * Int(pixels[index + 1])
            let blue = 72 * Int(pixels[index + 2])
            let gray = UInt8(min(255, (red + green + blue + 500) / 1000))
            pixels[index] = gray; pixels[index + 1] = gray; pixels[index + 2] = gray
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: original.width, height: original.height,
                                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: original.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw EditorError.renderingFailed }
        return UIImage(cgImage: image)
    }

    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let succeeded = result.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard succeeded else { throw EditorError.renderingFailed }
        return result
    }

    private static func argb(_ image: CGImage) throws -> [UInt32] {
        let pixels = try rgba(image)
        return stride(from: 0, to: pixels.count, by: 4).map { index in
            let alpha = UInt32(pixels[index + 3])
            guard alpha > 0 else { return 0 }
            // NativeImage expects straight ARGB, not Core Graphics' premultiplied channels.
            let red = min(255, UInt32(pixels[index]) * 255 / alpha)
            let green = min(255, UInt32(pixels[index + 1]) * 255 / alpha)
            let blue = min(255, UInt32(pixels[index + 2]) * 255 / alpha)
            return alpha << 24 | red << 16 | green << 8 | blue
        }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
    var normalizedAngle: CGFloat {
        var angle = (self + .pi).truncatingRemainder(dividingBy: .pi * 2)
        if angle < 0 { angle += .pi * 2 }
        return angle - .pi
    }
}

private extension CGPoint {
    func rotated(_ angle: CGFloat) -> CGPoint {
        CGPoint(x: x * cos(angle) - y * sin(angle), y: x * sin(angle) + y * cos(angle))
    }
}
