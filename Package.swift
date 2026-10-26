// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "lanTV",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "lanTV",
            targets: ["lanTV"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "VLCKit",
            path: "Vendor/VLCKit.xcframework"
        ),
        .executableTarget(
            name: "lanTV",
            dependencies: ["VLCKit"]
        )
    ]
)
