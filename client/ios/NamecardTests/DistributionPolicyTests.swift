import NamecardCore
import XCTest
@testable import Namecard

@MainActor
final class DistributionPolicyTests: XCTestCase {
    func testCompiledChannelMatchesProcessedInfoAndDoesNotUseBenchProfileForBeta() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NamecardDistributionChannel") as? String,
                       HardwareValidation.distributionChannel)
        #if NAMECARD_BETA
        XCTAssertTrue(HardwareValidation.isBetaBuild)
        XCTAssertEqual(HardwareValidation.distributionChannel, "beta")
        XCTAssertEqual(HardwareValidation.profile.isBetaTesting, HardwareValidation.allowsDisplayWrites)
        XCTAssertFalse(HardwareValidation.profile.isDeveloperTesting)
        XCTAssertNil(HardwareValidation.profile.validationReference)
        #elseif HARDWARE_TESTING
        XCTAssertFalse(HardwareValidation.isBetaBuild)
        XCTAssertTrue(HardwareValidation.profile.isDeveloperTesting)
        XCTAssertFalse(HardwareValidation.profile.isBetaTesting)
        #else
        XCTAssertFalse(HardwareValidation.isBetaBuild)
        XCTAssertFalse(HardwareValidation.profile.isBetaTesting)
        XCTAssertFalse(HardwareValidation.profile.isDeveloperTesting)
        XCTAssertEqual(HardwareValidation.allowsDisplayWrites, HardwareValidation.measuredDevice != nil)
        #endif
    }

    func testBetaAudienceCanBeBroadOrRestrictedWithoutClaimingHardwareValidation() throws {
        let broad = try XCTUnwrap(BetaDistribution.configuration)
        XCTAssertTrue(broad.isValid)
        let restricted = BetaDistribution.Configuration(schemaVersion: 1, minimumIOSMajor: 17,
                                                        deviceModels: ["iPhone11,8"], iOSMajorVersions: [18])
        XCTAssertTrue(restricted.allows(model: "iPhone11,8", iOSMajor: 18))
        XCTAssertFalse(restricted.allows(model: "iPhone11,8", iOSMajor: 17))
        XCTAssertFalse(restricted.allows(model: "iPhone11,8", iOSMajor: 26))
        XCTAssertFalse(restricted.allows(model: "iPhone99,1", iOSMajor: 18))
        let all = BetaDistribution.Configuration(schemaVersion: 1, minimumIOSMajor: 17,
                                                deviceModels: [], iOSMajorVersions: [])
        XCTAssertTrue(all.allows(model: "iPhone99,1", iOSMajor: 26))
        XCTAssertFalse(all.allows(model: "iPhone11,8", iOSMajor: 16))
        let invalid = BetaDistribution.Configuration(schemaVersion: 2, minimumIOSMajor: 17,
                                                    deviceModels: [], iOSMajorVersions: [])
        XCTAssertFalse(invalid.allows(model: "iPhone11,8", iOSMajor: 18))
    }
}
