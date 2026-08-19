// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "J6Handset",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "J6Handset",
            targets: ["J6Handset"]
        )
    ],
    targets: [
        .target(
            name: "J6Handset"
        )
    ],
    swiftLanguageModes: [.v5]
)
