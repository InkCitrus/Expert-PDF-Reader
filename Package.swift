// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenPDFExpert",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OpenPDFExpert", targets: ["OpenPDFExpert"])
    ],
    targets: [
        .executableTarget(
            name: "OpenPDFExpert",
            path: "Sources/OpenPDFExpert",
            exclude: [
                "Shaders/RDPDFShaders.metal"
            ],
            resources: [
                .copy("Resources/RDPDFShaders.metallib")
            ]
        )
    ]
)
