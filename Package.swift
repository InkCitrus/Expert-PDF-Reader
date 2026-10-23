// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ExpertPDFReader",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ExpertPDFReader", targets: ["ExpertPDFReader"])
    ],
    targets: [
        .executableTarget(
            name: "ExpertPDFReader",
            path: "Sources/ExpertPDFReader",
            exclude: [
                "Shaders/RDPDFShaders.metal"
            ],
            resources: [
                .copy("Resources/RDPDFShaders.metallib"),
                .copy("Resources/en.lproj"),
                .copy("Resources/zh-Hans.lproj")
            ]
        )
    ]
)
