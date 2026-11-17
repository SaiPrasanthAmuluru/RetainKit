// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "retainkit",
    platforms: [.macOS(.v13)],
    products: [
        // The detection engine, for embedding in other tools
        // (an Xcode extension, a macOS app).
        .library(name: "RetainKitCore", targets: ["RetainKitCore"]),
        // The command-line scanner.
        .executable(name: "retainkit", targets: ["retainkit"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-syntax.git",
            from: "510.0.0"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.3.0"
        ),
    ],
    targets: [
        .target(
            name: "RetainKitCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            path: "Sources/RetainKitCore"
        ),
        .executableTarget(
            name: "retainkit",
            dependencies: [
                "RetainKitCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/retainkit"
        ),
        .testTarget(
            name: "RetainKitTests",
            dependencies: [
                "RetainKitCore",
                "retainkit",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tests/RetainKitTests",
            // Xcode test plan, not a source file or resource.
            exclude: ["retainkit.xctestplan"]
        ),
    ]
)
