import Foundation
import XCTest
@testable import NamecardCore

final class NativeImageTests: XCTestCase {
    func testEveryByteMatchesAndroidGolden() throws {
        let argb = (0..<(296 * 128)).map { UInt32(truncatingIfNeeded: UInt64($0) * 1_103_515_245 + 12_345) }
        for (format, name) in [(ImageFormat.dotDensity, "android-dot-density"), (.gray4, "android-gray4")] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures"))
            XCTAssertEqual(try NativeImage.encode(argb: argb, format: format), try Data(contentsOf: url))
        }
    }

    func testTransparentBlackCompositesOnWhite() throws {
        let pixels = [UInt32](repeating: 0x00000000, count: 296 * 128)
        XCTAssertEqual(try NativeImage.encode(argb: pixels, format: .dotDensity), Data(repeating: 255, count: 4_736))
        XCTAssertEqual(try NativeImage.encode(argb: pixels, format: .gray4), Data(repeating: 0, count: 9_472))
    }

    func testNativeOrderAndMSBFirst() throws {
        var pixels = [UInt32](repeating: 0xffffffff, count: 296 * 128)
        pixels[0] = 0xff000000
        pixels[127 * 296 + 295] = 0xff000000
        let encoded = try NativeImage.encode(argb: pixels, format: .dotDensity)
        XCTAssertEqual(encoded[0], 0x7f)
        XCTAssertEqual(encoded[4_735], 0xfe)
        XCTAssertEqual(try NativeImage.decode(encoded, format: .dotDensity), pixels)
    }

    func testGrayQuantizationBoundariesAndPlanes() throws {
        var pixels = [UInt32](repeating: 0xffffffff, count: 296 * 128)
        let levels: [UInt32] = [0x3f, 0x40, 0x7f, 0x80, 0xbf, 0xc0]
        for (index, level) in levels.enumerated() { pixels[index] = 0xff000000 | level << 16 | level << 8 | level }
        let bytes = try NativeImage.encode(argb: pixels, format: .gray4)
        XCTAssertEqual((0..<6).map { bytes[$0 * 16] }, [0x80, 0, 0, 0x80, 0x80, 0])
        XCTAssertEqual((0..<6).map { bytes[4_736 + $0 * 16] }, [0x80, 0x80, 0x80, 0, 0, 0])
        XCTAssertEqual(Array(try NativeImage.decode(bytes, format: .gray4).prefix(6)), [0xff000000, 0xff555555, 0xff555555, 0xffaaaaaa, 0xffaaaaaa, 0xffffffff])
    }

    func testBinSizesAndPixelCountAreStrict() throws {
        XCTAssertEqual(try NativeImage.format(byteCount: 4_736), .dotDensity)
        XCTAssertEqual(try NativeImage.format(byteCount: 9_472), .gray4)
        for count in [0, 4_735, 4_737, 9_471, 9_473] { XCTAssertThrowsError(try NativeImage.format(byteCount: count)) }
        XCTAssertThrowsError(try NativeImage.encode(argb: [], format: .dotDensity))
        XCTAssertThrowsError(try NativeImage.decode(Data(repeating: 0, count: 4_736), format: .gray4))
    }
}
