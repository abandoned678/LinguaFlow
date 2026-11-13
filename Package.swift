// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacInputMethod",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .library(name: "InputCore", targets: ["InputCore"]),
        .library(name: "RimeInput", targets: ["RimeInput"]),
        .executable(name: "InputMethod", targets: ["InputMethod"]),
        .executable(name: "TranslationSetup", targets: ["TranslationSetup"]),
        .executable(name: "input-core-checks", targets: ["InputCoreChecks"]),
        .executable(name: "rime-checks", targets: ["RimeChecks"]),
        .executable(name: "translation-checks", targets: ["TranslationChecks"]),
    ],
    targets: [
        .target(name: "InputCore"),
        .target(
            name: "RimeBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/opt/librime/include"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/opt/librime/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/opt/homebrew/opt/librime/lib",
                ]),
                .linkedLibrary("rime"),
            ]
        ),
        .target(
            name: "RimeInput",
            dependencies: ["RimeBridge"]
        ),
        .executableTarget(
            name: "InputMethod",
            dependencies: ["InputCore", "RimeInput"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("InputMethodKit"),
            ]
        ),
        .executableTarget(
            name: "TranslationSetup",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Translation"),
            ]
        ),
        .executableTarget(
            name: "InputCoreChecks",
            dependencies: ["InputCore"]
        ),
        .executableTarget(
            name: "RimeChecks",
            dependencies: ["RimeInput"]
        ),
        .executableTarget(
            name: "TranslationChecks",
            dependencies: ["InputCore"],
            linkerSettings: [
                .linkedFramework("Translation"),
            ]
        ),
        .testTarget(
            name: "InputCoreTests",
            dependencies: ["InputCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
