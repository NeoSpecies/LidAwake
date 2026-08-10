// swift-tools-version:6.0
import PackageDescription

// 注意：产品名故意避免仅大小写不同（如 LidAwake / lidawake），
// 否则在大小写不敏感的 APFS 上 .build/release 里会互相覆盖。
let package = Package(
    name: "LidAwakeSuite",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "lidawaked", targets: ["LidAwakeDaemon"]),
        .executable(name: "lidawake", targets: ["LidAwakeCLI"]),
        .executable(name: "lidawake-probe", targets: ["LidAwakeProbe"]),
        .executable(name: "LidAwakeUI", targets: ["LidAwakeUI"]),
        .executable(name: "lidawake-tests", targets: ["LidAwakeTestRunner"]),
    ],
    targets: [
        .target(
            name: "LidAwakeCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LidAwakeDaemon",
            dependencies: ["LidAwakeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LidAwakeCLI",
            dependencies: ["LidAwakeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LidAwakeProbe",
            dependencies: ["LidAwakeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LidAwakeUI",
            dependencies: ["LidAwakeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LidAwakeTestRunner",
            dependencies: ["LidAwakeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
