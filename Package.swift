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
            resources: [
                .copy("Resources/en.lproj"),
                .copy("Resources/zh-Hans.lproj"),
                .copy("Resources/zh-Hant.lproj"),
                .copy("Resources/ja.lproj"),
                .copy("Resources/ko.lproj"),
                .copy("Resources/fr.lproj"),
                .copy("Resources/de.lproj"),
                .copy("Resources/es.lproj"),
                .copy("Resources/it.lproj"),
                .copy("Resources/pt.lproj"),
                .copy("Resources/ru.lproj"),
                .copy("Resources/uk.lproj")
            ]
        )
    ]
)
