// swift-tools-version:5.9

// The protocol's types for Swift: the DTOs, enums, error codes and method and
// event tables `packages/conduit_protocol/tool/generate_swift.dart` writes
// into `Generated.swift`, and a JSON-RPC client over a transport the host
// supplies.
//
// Nothing links this package yet. It exists so the types can be checked with
// `swift test --package-path ios/ConduitProtocol` against the protocol's
// goldens in `packages/conduit_protocol/goldens`.

import PackageDescription

let package = Package(
  name: "ConduitProtocol",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [
    .library(name: "ConduitProtocol", targets: ["ConduitProtocol"]),
  ],
  targets: [
    .target(name: "ConduitProtocol"),
    .testTarget(name: "ConduitProtocolTests", dependencies: ["ConduitProtocol"]),
  ]
)
