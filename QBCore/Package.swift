// swift-tools-version: 6.2
// باكج Swift يغلّف نواة Rust: الـ XCFramework + الربط المولّد + الغلافات.
// الكود المولّد من UniFFI يبني بـ Swift 5 mode هنا، والتطبيق نفسه Swift 6.
import PackageDescription

let package = Package(
    name: "QBCore",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "QBCore", targets: ["QBCore"]),
    ],
    targets: [
        .binaryTarget(name: "QBCoreFFI", path: "QBCoreFFI.xcframework"),
        .target(
            name: "QBCore",
            dependencies: ["QBCoreFFI"],
            path: "Sources/QBCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("resolv"),
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "QBCoreTests",
            dependencies: ["QBCore"],
            path: "Tests/QBCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
