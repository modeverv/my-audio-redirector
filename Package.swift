// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MyRedirector",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MyRedirector", targets: ["RedirectorApp"]),
        .executable(name: "CoreTests", targets: ["RealtimeCoreTests"])
    ],
    targets: [
        .target(name: "CSamplerate", path: "Vendor/CSamplerate",
                exclude: ["COPYING", "README.md"],
                sources: ["samplerate.c", "src_linear.c", "src_sinc.c", "src_zoh.c"],
                publicHeadersPath: "include", cSettings: [.headerSearchPath("."), .define("HAVE_CONFIG_H")]),
        .target(name: "RealtimeCore", dependencies: ["CSamplerate"],
                publicHeadersPath: "include"),
        .target(name: "RedirectorBridge", dependencies: ["RealtimeCore"],
                publicHeadersPath: "include",
                cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("Foundation")]),
        .executableTarget(name: "RedirectorApp", dependencies: ["RedirectorBridge"],
                linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("AppKit"), .linkedFramework("AVFoundation")]),
        .executableTarget(name: "RealtimeCoreTests", dependencies: ["RealtimeCore"], path: "Tests/RealtimeCoreTests")
    ], cLanguageStandard: .c11, cxxLanguageStandard: .cxx17)
