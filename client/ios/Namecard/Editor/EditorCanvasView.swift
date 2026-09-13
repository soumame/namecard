import SwiftUI
import UIKit

struct EditorCanvasView: UIViewRepresentable {
    let model: EditorModel

    func makeUIView(context: Context) -> PaperCanvasUIView {
        PaperCanvasUIView(model: model)
    }

    func updateUIView(_ view: PaperCanvasUIView, context: Context) {
        _ = model.revision
        view.model = model
        view.setNeedsDisplay()
    }
}

/// Tracks a single multi-touch interaction so pan, scale and rotation form one undo operation.
final class PaperCanvasUIView: UIView {
    var model: EditorModel
    private var activeTouches = Set<UITouch>()
    private var previousPoints: [ObjectIdentifier: CGPoint] = [:]
    private var target: Target = .none
    private enum Target { case none, layer, viewport }

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .secondarySystemBackground
        clipsToBounds = true
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityLabel = "296 × 128 名刺の編集領域"
        accessibilityHint = "要素をドラッグして移動、2本指で拡縮・回転。灰色の余白から操作すると紙面表示を調整します。"
        accessibilityTraits = [.allowsDirectInteraction]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        let transform = model.viewport.transform(in: bounds.size)
        context.concatenate(transform)
        model.draw(in: context, decorations: true)
        context.setStrokeColor(UIColor.separator.cgColor)
        context.setLineWidth(1 / max(0.01, hypot(transform.a, transform.b)))
        context.stroke(EditorModel.paper)
        context.restoreGState()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if activeTouches.isEmpty, let first = touches.min(by: { $0.timestamp < $1.timestamp }) {
            let point = first.location(in: self).applying(model.viewport.transform(in: bounds.size).inverted())
            if EditorModel.paper.contains(point) {
                model.select(at: point)
                target = model.hasSelection ? .layer : .none
                if target == .layer { model.beginTransform() }
            } else {
                model.deselect()
                target = .viewport
                model.viewport.beginTransform()
            }
        }
        activeTouches.formUnion(touches)
        refreshPoints()
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let current = points()
        guard !current.isEmpty, current.keys.allSatisfy({ previousPoints[$0] != nil }) else {
            previousPoints = current
            return
        }
        let before = centroid(previousPoints)
        let after = centroid(current)
        let pan = CGPoint(x: after.x - before.x, y: after.y - before.y)
        var zoom: CGFloat = 1
        var rotation: CGFloat = 0
        if current.count > 1 {
            var oldRadius: CGFloat = 0
            var newRadius: CGFloat = 0
            var cosine: CGFloat = 0
            var sine: CGFloat = 0
            for (id, point) in current {
                guard let old = previousPoints[id] else { continue }
                let oldVector = CGPoint(x: old.x - before.x, y: old.y - before.y)
                let newVector = CGPoint(x: point.x - after.x, y: point.y - after.y)
                oldRadius += hypot(oldVector.x, oldVector.y)
                newRadius += hypot(newVector.x, newVector.y)
                cosine += oldVector.x * newVector.x + oldVector.y * newVector.y
                sine += oldVector.x * newVector.y - oldVector.y * newVector.x
            }
            if oldRadius > 1 { zoom = newRadius / oldRadius }
            if abs(cosine) + abs(sine) > 0.01 { rotation = atan2(sine, cosine) }
        }
        switch target {
        case .none: break
        case .layer:
            let inverse = model.viewport.transform(in: bounds.size).inverted()
            let paperPan = CGSize(width: pan.x, height: pan.y).applying(inverse)
            model.transformSelection(pan: CGPoint(x: paperPan.width, y: paperPan.height),
                                     zoom: zoom, rotation: rotation)
        case .viewport:
            model.viewport.apply(pan: pan, zoom: zoom, rotation: rotation, focus: before, size: bounds.size,
                                 rotationSnapEnabled: model.viewportRotationSnapEnabled)
        }
        previousPoints = current
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { finish(activeTouches) }
    }

    private func finish(_ touches: Set<UITouch>) {
        activeTouches.subtract(touches)
        if activeTouches.isEmpty {
            if target == .layer { model.endTransform() }
            if target == .viewport { model.viewport.endTransform() }
            target = .none
        }
        refreshPoints()
        setNeedsDisplay()
    }

    private func points() -> [ObjectIdentifier: CGPoint] {
        Dictionary(uniqueKeysWithValues: activeTouches.map { (ObjectIdentifier($0), $0.location(in: self)) })
    }

    private func refreshPoints() { previousPoints = points() }

    private func centroid(_ points: [ObjectIdentifier: CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.values.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}
