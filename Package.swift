// swift-tools-version:6.0
import PackageDescription

// Swift 5 language mode: strict concurrency fights IOKit C APIs, XPC delegates and
// timer callbacks throughout this project. @MainActor is still used deliberately.
let langMode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "MacFanSpeed",
    platforms: [.macOS(.v14)],
    targets: [
        // Declarations for the private IOKit HID symbols used to read Apple
        // Silicon temperature sensors. See Sources/CIOHIDShim/include.
        .target(name: "CIOHIDShim"),

        // Shared SMC + sensor layer. Used by the app, the helper and the CLI.
        .target(
            name: "SMCKit",
            dependencies: ["CIOHIDShim"],
            swiftSettings: langMode,
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Menu bar app. Assembled into MacFanSpeed.app by scripts/build.sh.
        .executableTarget(
            name: "MacFanSpeed",
            dependencies: ["SMCKit"],
            swiftSettings: langMode
        ),
        // Privileged daemon (root). Performs SMC writes on behalf of the app.
        .executableTarget(
            name: "FanHelper",
            dependencies: ["SMCKit"],
            swiftSettings: langMode,
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("AppKit"),
            ]
        ),
        // Debug CLI for exercising the SMC/sensor layer without the UI.
        .executableTarget(
            name: "fanctl",
            dependencies: ["SMCKit"],
            swiftSettings: langMode
        ),
        // Covers the hardware-independent logic — sensor classification and fan
        // range maths — so the portability rules stay verifiable off-device.
        .testTarget(
            name: "SMCKitTests",
            dependencies: ["SMCKit"],
            swiftSettings: langMode
        ),
        // Covers menu bar formatting, including the fanless and no-sensor display
        // paths that cannot be reproduced on the developer's hardware.
        .testTarget(
            name: "MacFanSpeedTests",
            dependencies: ["MacFanSpeed"],
            swiftSettings: langMode
        ),
    ]
)
