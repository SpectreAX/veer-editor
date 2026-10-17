// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VeerAIEditor",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "VeerAIEditor", targets: ["VeerEditorApp"])],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")],
    targets: [
        .target(name: "VeerCore", dependencies: ["Yams"]),
        .executableTarget(
            name: "VeerEditorApp",
            dependencies: ["VeerCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "VeerCoreTests", dependencies: ["VeerCore"]),
        .testTarget(name: "VeerEditorAppTests", dependencies: ["VeerEditorApp"]),
    ]
)
