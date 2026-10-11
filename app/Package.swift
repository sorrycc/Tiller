// swift-tools-version: 6.2
import PackageDescription

// Build through scripts/bundle.sh, which builds the Rust static library first
// and passes its directory to the linker.
let package = Package(
    name: "Tiller",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Updates. bundle.sh copies Sparkle.framework into the app.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .systemLibrary(name: "CTillerCore", path: "Sources/CTillerCore"),
        .executableTarget(
            name: "Tiller",
            dependencies: [
                "CTillerCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(name: "TillerTests", dependencies: ["Tiller"]),
    ]
)
