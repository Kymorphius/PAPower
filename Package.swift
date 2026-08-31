// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PAPower",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PAPower", targets: ["PAPower"])
    ],
    targets: [
        .executableTarget(
            name: "PAPower",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
