// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tuck",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Tuck", targets: ["Tuck"])],
    targets: [
        .target(name: "TuckCore"),
        .target(name: "NativeVisibility", publicHeadersPath: "include"),
        .executableTarget(name: "Tuck", dependencies: ["TuckCore", "NativeVisibility"]),
        .executableTarget(name: "TuckChecks", dependencies: ["TuckCore"], path: "Tests/TuckChecks")
    ]
)
