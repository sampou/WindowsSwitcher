// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowsSwitcher",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WindowsSwitcher", targets: ["WindowsSwitcher"])
    ],
    dependencies: [
        .package(url: "https://ghfast.top/https://github.com/soffes/HotKey", from: "0.2.0"),
        // Sparkle 暂时移除（二进制包需要直连 GitHub Releases，待网络恢复后添加）
    ],
    targets: [
        .executableTarget(
            name: "WindowsSwitcher",
            dependencies: [
                .product(name: "HotKey", package: "HotKey"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "WindowsSwitcherTests",
            dependencies: ["WindowsSwitcher"],
            path: "Tests"
        ),
    ]
)
