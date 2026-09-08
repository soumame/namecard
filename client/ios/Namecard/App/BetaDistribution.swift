import Foundation

/// TestFlight audience settings; never evidence of a validated device or route.
enum BetaDistribution {
    struct Configuration: Decodable {
        let schemaVersion: Int
        let minimumIOSMajor: Int
        let deviceModels: [String]
        let iOSMajorVersions: [Int]

        var isValid: Bool {
            schemaVersion == 1 && minimumIOSMajor >= 17 &&
            deviceModels.allSatisfy { !$0.isEmpty && $0.hasPrefix("iPhone") } &&
            iOSMajorVersions.allSatisfy { $0 >= minimumIOSMajor }
        }

        func allows(model: String, iOSMajor: Int) -> Bool {
            isValid && iOSMajor >= minimumIOSMajor &&
            (deviceModels.isEmpty || deviceModels.contains(model)) &&
            (iOSMajorVersions.isEmpty || iOSMajorVersions.contains(iOSMajor))
        }
    }

    static let configuration: Configuration? = {
        guard let url = Bundle.main.url(forResource: "BetaDistribution", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Configuration.self, from: data), value.isValid else { return nil }
        return value
    }()
}
