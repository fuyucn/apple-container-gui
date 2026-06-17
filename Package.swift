// swift-tools-version: 6.0
import PackageDescription

// This environment has only the Command Line Tools (no full Xcode). The
// swift-testing framework (`import Testing`) and its interop dylib ship inside
// CommandLineTools but are not on SwiftPM's default search/runtime paths, so the
// test bundle fails to compile/`dlopen` under a plain `swift test`. Bake the
// framework search path + rpaths into the test target so `swift test` works
// without extra `-Xswiftc`/`-Xlinker` flags on the command line.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltInteropLib = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "AppleContainerGUI",
    platforms: [.macOS(.v15)],
    dependencies: [
        // In-app interactive terminal emulator (Phase 8.3). Pinned to a tagged
        // release; only AppMain depends on it — Core stays dependency-free.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.5.0"),
    ],
    targets: [
        .target(name: "Core"),
        .executableTarget(
            name: "AppMain",
            dependencies: [
                "Core",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .unsafeFlags(["-F", cltFrameworks])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", cltFrameworks,
                    "-framework", "Testing",
                    "-L", cltInteropLib,
                    "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
                    "-Xlinker", "-rpath", "-Xlinker", cltInteropLib,
                ])
            ]
        ),
    ]
)
