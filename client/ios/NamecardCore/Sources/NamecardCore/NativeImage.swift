import Foundation

public enum ImageFormat: Int, Codable, CaseIterable, Sendable {
    case dotDensity = 1
    case gray4 = 2

    public var byteCount: Int { self == .dotDensity ? 4_736 : 9_472 }
    public var title: String { self == .dotDensity ? "ドット密度" : "4階調" }
}

public enum NativeImageError: Error, LocalizedError {
    case invalidPixelCount, invalidByteCount
    public var errorDescription: String? {
        switch self {
        case .invalidPixelCount: return "画像は296×128ピクセルで指定してください"
        case .invalidByteCount: return "BINは4,736 bytes（白黒）または9,472 bytes（4階調）で指定してください"
        }
    }
}

/// Android NativeImageFormat parity. Input is row-major, straight (not premultiplied) ARGB.
public enum NativeImage {
    public static let width = 296
    public static let height = 128
    private static let planeBytes = 4_736
    private static let bayer = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]

    public static func format(byteCount: Int) throws -> ImageFormat {
        guard let format = ImageFormat.allCases.first(where: { $0.byteCount == byteCount }) else {
            throw NativeImageError.invalidByteCount
        }
        return format
    }

    public static func encode(argb: [UInt32], format: ImageFormat) throws -> Data {
        guard argb.count == width * height else { throw NativeImageError.invalidPixelCount }
        var bytes = [UInt8](repeating: format == .dotDensity ? 0xff : 0, count: format.byteCount)
        for y in 0..<height {
            for x in 0..<width {
                let color = argb[y * width + x]
                let alpha = Int(color >> 24)
                let red = (Int((color >> 16) & 255) * alpha + 255 * (255 - alpha)) / 255
                let green = (Int((color >> 8) & 255) * alpha + 255 * (255 - alpha)) / 255
                let blue = (Int(color & 255) * alpha + 255 * (255 - alpha)) / 255
                let luminance = (299 * red + 587 * green + 114 * blue) / 1_000
                let index = x * (height / 8) + y / 8
                let mask = UInt8(0x80 >> (y & 7))
                if format == .dotDensity {
                    if luminance < bayer[y & 3][x & 3] * 16 + 8 { bytes[index] &= ~mask }
                } else {
                    let code = min(3, luminance / 64)
                    if code & 1 == 0 { bytes[index] |= mask }
                    if code & 2 == 0 { bytes[planeBytes + index] |= mask }
                }
            }
        }
        return Data(bytes)
    }

    public static func decode(_ data: Data, format: ImageFormat) throws -> [UInt32] {
        guard data.count == format.byteCount else { throw NativeImageError.invalidByteCount }
        let bytes = [UInt8](data)
        let shades: [UInt32] = [0xff000000, 0xff555555, 0xffaaaaaa, 0xffffffff]
        return (0..<(width * height)).map { pixel in
            let x = pixel % width, y = pixel / width
            let index = x * (height / 8) + y / 8
            let mask = UInt8(0x80 >> (y & 7))
            if format == .dotDensity { return bytes[index] & mask != 0 ? shades[3] : shades[0] }
            let low = bytes[index] & mask != 0 ? 0 : 1
            let high = bytes[planeBytes + index] & mask != 0 ? 0 : 2
            return shades[low + high]
        }
    }
}
