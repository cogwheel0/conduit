// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "flutter_callkit_incoming",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "flutter-callkit-incoming",
            targets: ["flutter_callkit_incoming"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.8.0")
    ],
    targets: [
        .target(
            name: "flutter_callkit_incoming",
            dependencies: [
                .product(name: "CryptoSwift", package: "CryptoSwift")
            ],
            path: "Classes",
            resources: [.process("PrivacyInfo.xcprivacy")]
        )
    ]
)
