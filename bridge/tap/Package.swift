// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Embedded into the binary so TCC has a usage string for the audio capture prompt.
let infoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Support/Info.plist").path

let package = Package(
    name: "omarock-tap",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "omarock-tap", targets: ["omarock-tap"]),
        .library(name: "ProcessTap", targets: ["ProcessTap"]),
    ],
    targets: [
        .target(
            name: "ProcessTap",
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]
        ),
        .executableTarget(
            name: "omarock-tap",
            dependencies: ["ProcessTap"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
