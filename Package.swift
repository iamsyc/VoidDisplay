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
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "WebRTCBinary",
            url: "https://github.com/stasel/WebRTC/releases/download/147.0.0/WebRTC-M147.xcframework.zip",
            checksum: "49f9b1713432c19f408e3218fc8526c7692fafca5869f7ec5f5991614276ed40"
        ),
        .target(
            name: "WebRTC",
            dependencies: [
                "WebRTCBinary"
            ],
            path: "Vendor/WebRTCHeaders/M147",
            publicHeadersPath: "include"
        ),
        .target(
            name: "VoidDisplayApp",
            dependencies: [
                "VoidDisplayVirtualDisplay",
                "VoidDisplayCGVirtualDisplay",
                "VoidDisplayCapture",
                "VoidDisplaySharing",
                "VoidDisplaySupport",
                "VoidDisplayObservability",
                "VoidDisplayRuntime",
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
                "WebRTC"
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
            name: "VoidDisplayRuntime",
            dependencies: [
                "VoidDisplayFoundation",
                "VoidDisplayObservability"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "VoidDisplaySupport",
            dependencies: [
                "VoidDisplayDesignSystem",
                "VoidDisplayFoundation",
                "VoidDisplayObservability",
                "VoidDisplayRuntime"
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
                "VoidDisplayRuntime",
                "VoidDisplayFoundation",
                "VoidDisplayTestingSupport",
                "VoidDisplaySharingTestingSupport",
                "VoidDisplayVirtualDisplayTestingSupport"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "VoidDisplayVirtualDisplayTests",
            dependencies: [
                "VoidDisplayVirtualDisplay",
                "VoidDisplayTestingSupport",
                "VoidDisplayVirtualDisplayTestingSupport"
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
                "VoidDisplaySharing",
                "VoidDisplayTestingSupport",
                "VoidDisplaySharingTestingSupport"
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
            name: "VoidDisplayRuntimeTests",
            dependencies: [
                "VoidDisplayRuntime",
                "VoidDisplayFoundation",
                "VoidDisplayObservability",
                "VoidDisplayTestingSupport"
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "VoidDisplaySupportTests",
            dependencies: [
                "VoidDisplaySupport",
                "VoidDisplayObservability",
                "VoidDisplayRuntime",
                "VoidDisplayFoundation",
                "VoidDisplayTestingSupport"
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
        ),
        .target(
            name: "VoidDisplaySharingTestingSupport",
            dependencies: [
                "VoidDisplaySharing",
                "VoidDisplayFoundation"
            ],
            path: "Tests/VoidDisplaySharingTestingSupport",
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "VoidDisplayVirtualDisplayTestingSupport",
            dependencies: [
                "VoidDisplayVirtualDisplay",
                "VoidDisplayFoundation"
            ],
            path: "Tests/VoidDisplayVirtualDisplayTestingSupport",
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
