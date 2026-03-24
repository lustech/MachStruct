// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MachStruct",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MachStructCore", targets: ["MachStructCore"]),
        .executable(name: "MachStruct", targets: ["MachStruct"]),
    ],
    targets: [
        // System library shim for the Homebrew-installed simdjson (Apple Silicon path).
        // Install: brew install simdjson
        // On Intel Macs the prefix is /usr/local instead of /opt/homebrew — update
        // module.modulemap if needed. Proper pkg-config support is a future P1-03 polish task.
        .systemLibrary(
            name: "CSystemSimdjson",
            path: "Sources/CSystemSimdjson",
            providers: [.brew(["simdjson"])]
        ),

        // C++ bridge: thin extern "C" wrapper around simdjson.
        // Exposes ms_build_structural_index() consumed by JSONParser (P1-06).
        .target(
            name: "CSimdjsonBridge",
            dependencies: ["CSystemSimdjson"],
            path: "Sources/CSimdjsonBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                // Point the compiler at the Homebrew simdjson header.
                // The systemLibrary target above also provides this path, but
                // adding it explicitly ensures CSimdjsonBridge.cpp can #include "simdjson.h".
                .unsafeFlags(["-I/opt/homebrew/include"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib", "-lsimdjson"]),
            ]
        ),

        // Core library: data model, file I/O, parser protocol stubs.
        // Full parser implementations: P1-05 (StructParser), P1-06 (JSONParser).
        .target(
            name: "MachStructCore",
            dependencies: ["CSimdjsonBridge"],
            path: "MachStruct/Core"
        ),

        // macOS app: SwiftUI lifecycle + placeholder UI.
        // Full UI: P1-07 (StructDocument), P1-08 (TreeView), P1-09 (StatusBar).
        .executableTarget(
            name: "MachStruct",
            dependencies: ["MachStructCore"],
            path: "MachStruct/App"
        ),

        .testTarget(
            name: "MachStructTests",
            dependencies: ["MachStructCore", "CSimdjsonBridge"],
            path: "MachStructTests"
        ),
    ],
    // C++17 required by simdjson 4.x.
    cxxLanguageStandard: .cxx17
)
