// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NamecardCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "NamecardCore", targets: ["NamecardCore"])],
    targets: [
        .target(name: "NamecardCore"),
        .testTarget(name: "NamecardCoreTests", dependencies: ["NamecardCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
