// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "BurnZombies",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "BurnZombiesApp", targets: ["BurnApp"]),
    .executable(name: "burnzombies", targets: ["BurnCLI"]),
    .library(name: "BurnCore", targets: ["BurnCore"]),
  ],
  targets: [
    .target(name: "CBurn"),
    .target(name: "BurnCore", dependencies: ["CBurn"]),
    .executableTarget(
      name: "BurnApp", dependencies: ["BurnCore"], resources: [.process("Resources")]),
    .executableTarget(name: "BurnCLI", dependencies: ["BurnCore", "CBurn"]),
    .executableTarget(name: "BurnProof", dependencies: ["BurnCore", "CBurn"], path: "Proof"),
  ],
  swiftLanguageModes: [.v5]
)
