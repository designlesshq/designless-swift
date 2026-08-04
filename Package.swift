// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DesignlessKit",
    // Registering a font at runtime needs CoreText, which is on every Apple
    // platform. The floors are where async/await and the modern URLSession
    // land, not where the brand work needs them.
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8), .visionOS(.v1)],
    products: [
        .library(name: "DesignlessKit", targets: ["DesignlessKit"]),
    ],
    targets: [
        // No dependencies. The client speaks HTTP through an injected fetcher
        // and JSON through Foundation, so nothing here constrains what an app
        // already uses.
        .target(name: "DesignlessKit"),
        .testTarget(
            name: "DesignlessKitTests",
            dependencies: ["DesignlessKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
