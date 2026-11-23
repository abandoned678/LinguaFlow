// swift-tools-version: 6.0

import PackageDescription
import Foundation

let testingIME = ProcessInfo.processInfo.environment["SENTENCEALONG_TEST_BUILD"] == "1"

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
        .target(name: "InputSession", dependencies: ["RimeInput"]),
        .target(name: "IMETrace", path: "Tools/IMETesting/Trace"),
        .executableTarget(name: "IMEHost", dependencies: ["IMETrace"], path: "Tools/IMETesting/Host", exclude: ["Info.plist"]),
        .executableTarget(name: "IMERunner", dependencies: ["IMETrace", "InputCore"], path: "Tools/IMETesting/Runner"),
        .testTarget(name: "IMETraceTests", dependencies: ["IMETrace"]),
        .testTarget(name: "InputSessionTests", dependencies: ["InputSession", "RimeInput", "InputCore"]),
        .target(name: "LocalTranslation", dependencies: ["InputCore"]),
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
            dependencies: ["InputCore", "LocalTranslation", "RimeInput", "InputSession"] + (testingIME ? ["IMETrace"] : []),
            swiftSettings: testingIME ? [.define("IME_TEST_BUILD", .when(configuration: .debug))] : [],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("InputMethodKit"),
            ]
        ),
        .executableTarget(
            name: "TranslationSetup",
            dependencies: ["InputCore", "LocalTranslation"],
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
            dependencies: ["InputCore", "LocalTranslation"],
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
