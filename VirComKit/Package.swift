// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VirComKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "VirComKit", targets: ["VirComKit"])
    ],
    targets: [
        .target(
            name: "VirComKit",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(name: "VirComKitTests", dependencies: ["VirComKit"]),
    ],
    swiftLanguageModes: [.v6]
)
