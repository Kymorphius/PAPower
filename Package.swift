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
        .target(
            name: "PAPowerTemperatureBridge",
            path: "Sources/PAPowerTemperatureBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "PAPower",
            dependencies: ["PAPowerTemperatureBridge"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
