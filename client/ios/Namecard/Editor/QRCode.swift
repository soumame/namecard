import CoreImage.CIFilterBuiltins
import NamecardCore
import UIKit

enum QRCodeError: LocalizedError {
    case tooLong, generationFailed

    var errorDescription: String? {
        switch self {
        case .tooLong: "URLが長すぎます。短いURLを入力してください。"
        case .generationFailed: "QRコードを作成できませんでした。URLを確認してください。"
        }
    }
}

struct QRCode {
    let url: String
    private let modules: CGImage
    var moduleCount: Int { modules.width }
    var canvasScale: Int { 120 / moduleCount }
    var canAddToCanvas: Bool { canvasScale >= 2 }
    var previewScale: Int { max(1, 512 / moduleCount) }

    static func generate(_ input: String) throws -> QRCode {
        let url = try URLCodec.normalize(input)
        guard url.utf8.count <= 2_000 else { throw QRCodeError.tooLong }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { throw QRCodeError.generationFailed }
        // Preserve the generator's own margin and add four white modules on
        // every side. Integer scaling keeps both modules and quiet zone crisp.
        let extent = output.extent.insetBy(dx: -4, dy: -4)
        let white = CIImage(color: CIColor.white).cropped(to: extent)
        guard let modules = CIContext().createCGImage(output.composited(over: white), from: extent) else {
            throw QRCodeError.generationFailed
        }
        return QRCode(url: url, modules: modules)
    }

    func image(scale: Int) throws -> UIImage {
        guard (1...32).contains(scale) else { throw QRCodeError.generationFailed }
        let side = moduleCount * scale
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw QRCodeError.generationFailed
        }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.draw(modules, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else { throw QRCodeError.generationFailed }
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }
}
