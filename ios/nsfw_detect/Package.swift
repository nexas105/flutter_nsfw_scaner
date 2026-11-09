// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nsfw_detect",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "nsfw-detect", targets: ["nsfw_detect"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "nsfw_detect",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .copy("Resources/OpenNSFW2.mlmodelc")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
