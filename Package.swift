// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "am-i-cooked",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "cooked", targets: ["Cooked"])],
    targets: [
        .target(name: "CookedCore"),
        .executableTarget(name: "Cooked", dependencies: ["CookedCore"]),
        .testTarget(name: "CookedCoreTests", dependencies: ["CookedCore"])
    ]
)
