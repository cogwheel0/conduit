// swift-tools-version:5.9

// The Conduit push receiver: Web Push decryption, the `cp/1` payload, and the
// shared stores the app and its Notification Service Extension both read.
//
// Xcode does not depend on this package. Runner and the NotificationService
// extension compile `Sources/ConduitPushCore` directly, so their code never
// imports `ConduitPushCore`. The package exists so the logic can be tested
// with `swift test --package-path ios/ConduitPushCore` against the shared
// vectors in `push/test-vectors`.

import PackageDescription

let package = Package(
  name: "ConduitPushCore",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [
    .library(name: "ConduitPushCore", targets: ["ConduitPushCore"]),
  ],
  targets: [
    .target(name: "ConduitPushCore"),
    .testTarget(name: "ConduitPushCoreTests", dependencies: ["ConduitPushCore"]),
  ]
)
