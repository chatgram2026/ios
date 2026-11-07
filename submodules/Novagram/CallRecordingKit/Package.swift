// swift-tools-version:6.0
// SPDX-License-Identifier: GPL-2.0-or-later
import PackageDescription

let package = Package(
    name: "NovagramCallRecordingKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v10_13)
    ],
    products: [
        .library(name: "NovagramCallRecordingCore", targets: ["NovagramCallRecordingCore"]),
        .library(name: "NovagramCallRecordingUI", targets: ["NovagramCallRecordingUI"])
    ],
    targets: [
        .target(
            name: "NovagramCallRecordingCore",
            path: "Sources/NovagramCallRecordingCore"
        ),
        .target(
            name: "NovagramCallRecordingUI",
            dependencies: ["NovagramCallRecordingCore"],
            path: "Sources/NovagramCallRecordingUI"
        ),
        .testTarget(
            name: "NovagramCallRecordingCoreTests",
            dependencies: ["NovagramCallRecordingCore"],
            path: "Tests/NovagramCallRecordingCoreTests"
        ),
        .testTarget(
            name: "NovagramCallRecordingUITests",
            dependencies: ["NovagramCallRecordingUI", "NovagramCallRecordingCore"],
            path: "Tests/NovagramCallRecordingUITests"
        )
    ],
    swiftLanguageModes: [.v6]
)
