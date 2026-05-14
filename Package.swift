// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Restless",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Restless", targets: ["Restless"])
    ],
    targets: [
        .executableTarget(
            name: "Restless",
            path: "Sources/ScreenStay",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        )
    ]
)
