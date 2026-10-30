// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MurmurKit",
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [
    .library(name: "MurmurKit", targets: ["MurmurKit"])
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1")
  ],
  targets: [
    .target(
      name: "MurmurKit",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
    ),
    .testTarget(
      name: "MurmurKitTests",
      dependencies: ["MurmurKit"],
      path: "Tests",
      exclude: ["Fixtures/live"],
      sources: ["MurmurKitTests"],
      resources: [.copy("Fixtures/zoom")]
    ),
  ]
)
