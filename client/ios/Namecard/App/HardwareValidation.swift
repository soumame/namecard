import Foundation
import NamecardCore
import UIKit

/// Empty until measured on sold boards; simulator results never populate this file.
enum HardwareValidation {
    struct Device: Codable {
        let model: String
        let iOSMajor: Int
        let evidence: String
        let normalSeconds: Double
        let batchSeconds: Double?
        let legacySeconds: Double?
        let completedRuns: Int
    }
    struct Manifest: Codable {
        let schemaVersion: Int
        let devices: [Device]
    }
    static var model: String {
        var info = utsname()
        uname(&info)
        let capacity = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }
    static var measuredDevice: Device? {
        guard let url = Bundle.main.url(forResource: "HardwareValidation", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.schemaVersion == 1 else { return nil }
        return manifest.devices.first {
            $0.model == model && $0.iOSMajor == ProcessInfo.processInfo.operatingSystemVersion.majorVersion &&
            $0.completedRuns >= 10 && !$0.evidence.isEmpty &&
            [$0.normalSeconds, $0.batchSeconds, $0.legacySeconds].compactMap { $0 }.allSatisfy { $0 >= 2.25 && $0 < 50 }
        }
    }
    static var allowsDisplayWrites: Bool {
        #if HARDWARE_TESTING
        true
        #else
        measuredDevice != nil
        #endif
    }
    static var profile: HardwareProfile {
        #if HARDWARE_TESTING
        .developerTesting
        #else
        guard let device = measuredDevice else { return .unvalidated }
        return (try? HardwareProfile(validationReference: device.evidence,
                                     normalRefreshSeconds: device.normalSeconds,
                                     batchRefreshSeconds: device.batchSeconds,
                                     legacyRefreshSeconds: device.legacySeconds)) ?? .unvalidated
        #endif
    }
    static var explanation: String {
        #if HARDWARE_TESTING
        "実機検証用ビルドです。更新時間は仮設定で、給電を測定しながら試験してください。"
        #else
        allowsDisplayWrites ? "この端末の表示書き換えは検証済みです。" : "この端末での給電・表示更新は検証前のため、表示への書き込みは準備中です。編集・BIN保存・URL設定・STATUS確認を利用できます。"
        #endif
    }
}
