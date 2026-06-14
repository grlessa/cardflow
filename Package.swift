// swift-tools-version: 6.0
import PackageDescription

// Os alvos usam o modo de linguagem .v5 (mesmo com tools do Swift 6). O motor de cópia tem
// invariantes de thread única (claimed/bytesDone) e uma fila de verificação isolada; migrar pra
// verificação estrita de concorrência do Swift 6 é um trabalho à parte que não muda comportamento.
// Documentado pra não parecer descuido — ver CONTRIBUTING.md.
let package = Package(
    name: "OffloadKit",
    defaultLocalization: "pt-BR",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OffloadKit", targets: ["OffloadKit"]),
        .executable(name: "cardflow", targets: ["cardflow"]),
        .executable(name: "CardflowApp", targets: ["CardflowApp"]),
        .executable(name: "make-appcast", targets: ["make-appcast"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "OffloadKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OffloadKitTests",
            dependencies: ["OffloadKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CardflowCLI",
            dependencies: ["OffloadKit"],
            // `swift build` NÃO compila .xcstrings (validado: o .bundle saía só com o .xcstrings
            // cru, sem .lproj). A CLI roda via `swift run` (sem .app), então não há make-app.sh
            // pra compilar o catálogo. Solução: commitamos os <lang>.lproj/Localizable.strings
            // gerados por `xcrun xcstringstool compile` (ver Resources/README.md) — esses SIM o
            // `.process` empacota no bundle .module, e String(localized:bundle:.module) resolve
            // em runtime. O .xcstrings fica só como fonte de edição, EXCLUÍDO do target.
            exclude: ["Resources/Localizable.xcstrings", "Resources/README.md"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "cardflow",
            dependencies: ["CardflowCLI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CardflowCLITests",
            dependencies: ["CardflowCLI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CardflowApp",
            dependencies: [
                "OffloadKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // os String Catalogs do app são compilados pro bundle pelo scripts/make-app.sh
            // (xcstringstool), não pelo SwiftPM — então o SwiftPM ignora os .xcstrings.
            exclude: ["Resources/Localizable.xcstrings", "Resources/InfoPlist.xcstrings"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CardflowAppTests",
            dependencies: ["CardflowApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "make-appcast",
            dependencies: ["OffloadKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
