// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MachStruct",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MachStructCore", targets: ["MachStructCore"]),
        .executable(name: "MachStruct", targets: ["MachStruct"]),
    ],
    dependencies: [
        // Yams: Swift YAML parser wrapping libyaml (bundled — no brew install required).
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        // Sparkle 2: auto-update framework for macOS notarized DMG builds (P5-06).
        // Only linked by the app target; not needed by Core or tests.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.0.0"),
    ],
    targets: [
        // C++ bridge: thin extern "C" wrapper around simdjson.
        // Exposes ms_build_structural_index() consumed by JSONParser (P1-06).
        //
        // simdjson is vendored as a single-header amalgamation (v3.12.3) under
        // Sources/CSimdjsonBridge/vendor/ — no Homebrew install required.
        .target(
            name: "CSimdjsonBridge",
            dependencies: [],
            path: "Sources/CSimdjsonBridge",
            sources: ["MachStructBridge.cpp", "vendor/simdjson.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                // vendor/ contains the simdjson single-header amalgamation.
                .headerSearchPath("vendor"),
                // Disable C++ exceptions — simdjson uses error codes instead.
                .define("SIMDJSON_EXCEPTIONS", to: "0"),
            ]
        ),

        // Core library: data model, file I/O, parser protocol stubs.
        // Full parser implementations: P1-05 (StructParser), P1-06 (JSONParser),
        //                              P3-01 (XMLParser), P3-03 (YAMLParser).
        .target(
            name: "MachStructCore",
            dependencies: [
                "CSimdjsonBridge",
                .product(name: "Yams", package: "Yams"),
            ],
            path: "MachStruct/Core"
        ),

        // macOS app: SwiftUI lifecycle + placeholder UI.
        // Full UI: P1-07 (StructDocument), P1-08 (TreeView), P1-09 (StatusBar).
        .executableTarget(
            name: "MachStruct",
            dependencies: [
                "MachStructCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "MachStruct/App"
        ),

        .testTarget(
            name: "MachStructTests",
            dependencies: ["MachStructCore", "CSimdjsonBridge"],
            path: "MachStructTests"
        ),
    ],
    // C++17 required by simdjson.
    cxxLanguageStandard: .cxx17
)
