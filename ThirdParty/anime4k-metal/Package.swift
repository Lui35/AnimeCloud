// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Anime4KMetal",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "Anime4KMetal", targets: ["Anime4KMetal"]),
    ],
    targets: [
        .target(
            name: "Anime4KMetal",
            dependencies: ["Anime4KMetalCore"],
            path: "Anime4KMetal"
        ),
        .target(
            name: "Anime4KMetalCore",
            path: "Anime4KMetalCore",
            exclude: ["Shaders"],
            resources: [.copy("Resources/glsl")],
            plugins: [.plugin(name: "CompileAnime4KMetalShaders")]
        ),
        .plugin(
            name: "CompileAnime4KMetalShaders",
            capability: .buildTool()
        ),
    ]
)
