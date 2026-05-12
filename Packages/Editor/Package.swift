// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Editor",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(name: "Editor", type: .static, targets: ["Editor"])
    ],
    targets: [
        .target(
            name: "Editor",
            resources: [.process("Resources/Sounds")]
        ),
        .testTarget(
            name: "EditorTests",
            dependencies: ["Editor"]
        )
    ],
    swiftLanguageModes: [.v6]
)
