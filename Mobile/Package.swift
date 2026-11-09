// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "lanTVMobileCore", platforms: [.macOS(.v14), .iOS(.v17)], products: [.library(name: "MobileCore", targets: ["MobileCore"])], targets: [.target(name: "MobileCore", path: "Sources/lanTVMobile", exclude: ["MobileApp.swift", "MobileContentView.swift", "MobilePlayerView.swift", "MobileStore.swift"], sources: ["MobileCore.swift"]), .testTarget(name: "MobileCoreTests", dependencies: ["MobileCore"], path: "Tests")])
