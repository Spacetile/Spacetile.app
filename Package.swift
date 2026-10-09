// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Spacetile",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CSkyLight", targets: ["CSkyLight"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "CSkyLight",
            linkerSettings: [.unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])]
        ),
        // Pure tiling logic: no OS calls, fully unit-tested.
        .target(name: "SpacetileCore"),
        // Filesystem support for the optional command-line installation.
        .target(name: "SpacetileInstall"),
        // AppKit, AX and the event taps all run on the main thread, so the app is main-actor by default
        .executableTarget(name: "Spacetile",
                          dependencies: ["SpacetileCore", "SpacetileInstall", "CSkyLight", .product(name: "Sparkle", package: "Sparkle")],
                          swiftSettings: [.defaultIsolation(MainActor.self)],
                          // scripts/bundle.sh copies Sparkle.framework into Contents/Frameworks
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        // Exports the Keys catalogue and placement icons for the Raycast extension.
        .executableTarget(name: "spacetile-catalog", dependencies: ["SpacetileCore"]),
        .testTarget(name: "SpacetileCoreTests", dependencies: ["SpacetileCore"]),
        .testTarget(name: "SpacetileInstallTests", dependencies: ["SpacetileInstall"]),
    ]
)
