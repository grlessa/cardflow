import Testing
import Foundation

/// O catálogo de textos precisa compilar: o `swift build` não falha quando ele não compila, e o app
/// sairia mostrando as chaves. Regras que já quebraram: plural sem o número no texto. Regra de escrita:
/// nada de travessão no meio da frase.
@Suite struct StringCatalogTests {
    private func catalog() throws -> [String: [String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CardflowApp/Resources/Localizable.xcstrings")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return root["strings"] as! [String: [String: Any]]
    }

    @Test func semTravessao() throws {
        for (key, entry) in try catalog() {
            let locs = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for (lang, loc) in locs {
                let units = [(loc["stringUnit"] as? [String: Any])?["value"] as? String]
                    + ((loc["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] ?? [:]).values
                        .map { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
                for value in units.compactMap({ $0 }) {
                    #expect(!value.contains("—"), "\(key) [\(lang)] com travessão: \(value)")
                }
            }
        }
    }

    @Test func pluraisSempreMostramONumero() throws {
        for (key, entry) in try catalog() {
            let locs = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for (lang, loc) in locs {
                guard let plural = (loc["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] else { continue }
                for (q, v) in plural {
                    let value = (v["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
                    #expect(value.contains("%"), "\(key) [\(lang)/\(q)] sem o número: \(value)")
                }
            }
        }
    }
}
