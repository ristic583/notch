// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The official builds carry a license check that is not part of this
// repository. When its sources are present they replace the open stand-in.
let hasLicenseCheck = FileManager.default.fileExists(
    atPath: Context.packageDirectory + "/Sources/Notch/Services/License/Private")

let package = Package(
    name: "Notch",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Notch",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Notch",
            exclude: hasLicenseCheck ? ["Services/License/OpenLicense.swift"] : [],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
                .linkedFramework("IOKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ServiceManagement"),
                // Sparkle.framework is embedded in Contents/Frameworks by scripts/build-app.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "NotchTests",
            dependencies: ["Notch"],
            path: "Tests/NotchTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
