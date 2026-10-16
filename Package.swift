// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "retainkit",
    platforms: [.macOS(.v13)],
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
        .executableTarget(
            name: "retainkit",
            dependencies: [
                .product(name: "SwiftSyntax",    package: "swift-syntax"),
                .product(name: "SwiftParser",    package: "swift-syntax"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/retainkit"
        ),
        .testTarget(
            name: "RetainKitTests",
            dependencies: [
                "retainkit",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            path: "Tests/RetainKitTests"
        ),
    ]
)
