// swift-tools-version: 6.0
import PackageDescription

// libFLAC's encoder (reference libFLAC 1.5.0, from xiph/flac; see README.md), for the
// bridge's stream: its limit_min_bitrate keeps digital silence from shrinking to almost
// nothing, which Ogg FLAC clients behind Icecast fall behind on.
let package = Package(
    name: "omarock-flac",
    platforms: [.macOS("14.2")],
    products: [.library(name: "FLAC", targets: ["FLAC"])],
    targets: [
        .target(
            name: "FLAC",
            exclude: ["libFLAC/deduplication"],
            cSettings: [
                .headerSearchPath("libFLAC/include"),
                .define("PACKAGE_VERSION", to: "\"1.5.0\""),
                .define("FLAC__HAS_OGG", to: "0"),
                .define("FLAC__NO_ASM"),
                .define("ENABLE_64_BIT_WORDS", to: "1"),
                .define("HAVE_STDINT_H", to: "1"),
                .define("HAVE_INTTYPES_H", to: "1"),
                .define("HAVE_LROUND", to: "1"),
                .unsafeFlags(["-w"]),
            ]
        ),
    ]
)
