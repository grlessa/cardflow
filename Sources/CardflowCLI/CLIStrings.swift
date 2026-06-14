import Foundation

/// Localização da CLI.
///
/// `String(localized:bundle:.module)` NÃO serve aqui: o SPM, ao empacotar os recursos,
/// renomeia `pt-BR.lproj` para `pt-br.lproj` (minúsculo) dentro do `.bundle`. O CFBundle
/// usa casing sensível pra casar a localização preferida, então `pt-BR` do sistema não bate
/// com `pt-br` do bundle e cai no inglês. (Validado empiricamente — ver Resources/README.md.)
///
/// Solução: escolhemos o `.lproj` à mão, casando o idioma efetivo do sistema com o nome da
/// pasta de forma case-insensitive, e resolvemos a string nesse sub-bundle. O idioma já vem
/// filtrado para pt-BR/en/es (idioma não suportado cai em pt-BR, a fonte do catálogo).
enum CLIStrings {
    /// Idioma efetivo da CLI: `Locale.preferredLanguages` filtrado para os 3 suportados.
    /// Espelha o `AppLocale.effective` do app (que usa `Bundle.main.preferredLocalizations`),
    /// mas a CLI roda via `swift run`, sem `.app`/`.lproj` em `Bundle.main`.
    static var locale: String {
        let supported = ["pt-BR", "en", "es"]
        for tag in Locale.preferredLanguages {
            let base = tag.split(separator: "-").first.map(String.init) ?? tag
            if let hit = supported.first(where: { $0.split(separator: "-").first.map(String.init) == base }) {
                return hit
            }
        }
        return "pt-BR"
    }

    /// `.lproj` que casa com o idioma (case-insensitive, contornando o lowercasing do SPM).
    private static func bundle(for language: String) -> Bundle {
        let base = Bundle.module
        guard let resURL = base.resourceURL,
              let entries = try? FileManager.default.contentsOfDirectory(at: resURL, includingPropertiesForKeys: nil)
        else { return base }
        for url in entries where url.pathExtension == "lproj" {
            if url.deletingPathExtension().lastPathComponent.compare(language, options: .caseInsensitive) == .orderedSame {
                return Bundle(url: url) ?? base
            }
        }
        return base
    }

    /// Resolve a chave no idioma efetivo e aplica os argumentos com o `Locale` certo.
    static func string(_ key: String, _ args: CVarArg...) -> String {
        let language = locale
        let fmt = bundle(for: language).localizedString(forKey: key, value: nil, table: nil)
        guard !args.isEmpty else { return fmt }
        return String(format: fmt, locale: Locale(identifier: language), arguments: args)
    }

    /// `Locale` efetivo, pra passar ao motor (`CopyService(locale:)`) — nomes de pasta seguem a UI.
    static var effectiveLocale: Locale { Locale(identifier: locale) }
}
