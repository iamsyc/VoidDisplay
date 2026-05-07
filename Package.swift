// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VoidDisplay",
    defaultLocalization: "en",
    platforms: [
        .macOS("15.6")
    ],
    products: [
        .library(name: "VoidDisplayApp", targets: ["VoidDisplayApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", from: "147.0.0")
    ],
    targets: [
        .target(
            name: "VoidDisplayApp",
            dependencies: [
                "VoidDisplayVirtualDisplay",
                "VoidDisplayCGVirtualDisplay",
                "VoidDisplayCapture",
                "VoidDisplaySharing",
                "VoidDisplaySupport",
                "VoidDisplayObservability",
                "VoidDisplayFoundation"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "VoidDisplayVirtualDisplay",
            dependencies: [
                "VoidDisplayDesignSystem",
                "VoidDisplayFoundation",
                "VoidDisplayObservability"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "VoidDisplayCGVirtualDisplay",
            dependencies: [
                "VoidDisplayVirtualDisplay",
                "VoidDisplayFoundation",
                "CGVirtualDisplayPrivate"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "VoidDisplayCapture",
            dependencies: [
                "VoidDisplayDesignSystem",
                "VoidDisplayFoundation",
                "VoidDisplayObservability"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "VoidDisplaySharing",
            dependencies: [
                "VoidDisplayDesignSystem",
                "VoidDisplayFoundation",
                "VoidDisplayObservability",
                .product(name: "WebRTC", package: "WebRTC")
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "VoidDisplayObservability",
            dependencies: [
                "VoidDisplayFoundation"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "VoidDisplaySupport",
            dependencies: [
                "VoidDisplayDesignSystem",
                "VoidDisplayFoundation",
                "VoidDisplayObservability"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "VoidDisplayDesignSystem",
            dependencies: [
                "VoidDisplayFoundation"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "VoidDisplayFoundation",
            dependencies: [],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "CGVirtualDisplayPrivate",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
            ]
        ),
        .testTarget(
            name: "VoidDisplayAppTests",
            dependencies: [
                "VoidDisplayApp",
                "VoidDisplayVirtualDisplay",
                "VoidDisplayCapture",
                "VoidDisplaySharing",
                "VoidDisplaySupport",
                "VoidDisplayObservability",
                "VoidDisplayFoundation",
                "VoidDisplayTestingSupport"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "VoidDisplayVirtualDisplayTests",
            dependencies: [
                "VoidDisplayVirtualDisplay"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "VoidDisplayCGVirtualDisplayTests",
            dependencies: [
                "VoidDisplayCGVirtualDisplay"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "VoidDisplayCaptureTests",
            dependencies: [
                "VoidDisplayCapture"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "VoidDisplaySharingTests",
            dependencies: [
                "VoidDisplaySharing"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "VoidDisplayObservabilityTests",
            dependencies: [
                "VoidDisplayObservability"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "VoidDisplaySupportTests",
            dependencies: [
                "VoidDisplaySupport",
                "VoidDisplayObservability",
                "VoidDisplayFoundation"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "VoidDisplayDesignSystemTests",
            dependencies: [
                "VoidDisplayDesignSystem"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "VoidDisplayFoundationTests",
            dependencies: [
                "VoidDisplayFoundation",
                "VoidDisplayTestingSupport"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "VoidDisplayTestingSupport",
            dependencies: [
                "VoidDisplayFoundation"
            ],
            path: "Tests/VoidDisplayTestingSupport",
            swiftSettings: sharedSwiftSettings
        )
    ]
)

let sharedSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .defaultIsolation(MainActor.self)
]
