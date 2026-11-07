// swift-tools-version:6.0
// SPDX-License-Identifier: GPL-2.0-or-later
import PackageDescription

let package = Package(
    name: "NovagramReviewPromptKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v10_13)
    ],
    products: [
        .library(name: "NovagramReviewPromptCore", targets: ["NovagramReviewPromptCore"])
    ],
    targets: [
        .target(
            name: "NovagramReviewPromptCore",
            path: "Sources/NovagramReviewPromptCore"
        ),
        .testTarget(
            name: "NovagramReviewPromptCoreTests",
            dependencies: ["NovagramReviewPromptCore"],
            path: "Tests/NovagramReviewPromptCoreTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
