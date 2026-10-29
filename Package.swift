// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "BurnZombies",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "BurnZombiesApp", targets: ["BurnApp"]),
    .executable(name: "burnzombies", targets: ["BurnCLI"]),
    .executable(name: "burnzombies-mcp", targets: ["BurnMCP"]),
    .library(name: "BurnCore", targets: ["BurnCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    .package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.5.0"),
  ],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "CBurn", linkerSettings: [.linkedFramework("Security")]),
    .target(
      name: "BurnCore", dependencies: ["CBurn", "CSQLite"],
      resources: [.copy("Resources/BZGradleDaemon.java")]),
    .executableTarget(
      name: "BurnApp", dependencies: ["BurnCore"], resources: [.process("Resources")]),
    .executableTarget(
      name: "BurnCLI",
      dependencies: ["BurnCore", "CBurn", .product(name: "TOMLKit", package: "TOMLKit")]),
    .executableTarget(
      name: "BurnMCP", dependencies: ["BurnCore", .product(name: "MCP", package: "swift-sdk")]),
    .executableTarget(
      name: "BurnProof", dependencies: ["BurnCore", "CBurn", "CSQLite"], path: "Proof"),
  ],
  swiftLanguageModes: [.v5]
)
