// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "OmiLocalCore",
  platforms: [.macOS(.v14)],
  products: [.library(name: "OmiLocalCore", targets: ["OmiLocalCore"])],
  dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0")],
  targets: [
    .target(name: "OmiLocalCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
    .executableTarget(name: "LocalCoreChecks", dependencies: ["OmiLocalCore"], path: "Checks"),
  ]
)
