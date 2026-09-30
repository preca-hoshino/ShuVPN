// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "flutter_sangfor",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "flutter-sangfor", targets: ["flutter_sangfor"]),
        // Flutter-free core consumed by packet tunnel extension targets.
        .library(name: "SangforTunnelCore", targets: ["SangforTunnelCore"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        // NetworkExtension runtime shared by the Runner plugin and the
        // consumer app's .appex wrapper. MUST NOT import Flutter.
        .target(
            name: "SangforTunnelCore",
            dependencies: []
        ),
        .target(
            name: "flutter_sangfor",
            dependencies: [
                "SangforTunnelCore",
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // If your plugin requires a privacy manifest, for example if it uses any required
                // reason APIs, update the PrivacyInfo.xcprivacy file to describe your plugin's
                // privacy impact, and uncomment these lines. For more information, see
                // https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
                // .process("PrivacyInfo.xcprivacy"),

                // If you have other resources that need to be bundled with your plugin, refer to
                // the following instructions to add them:
                // https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package
            ]
        )
    ]
)
