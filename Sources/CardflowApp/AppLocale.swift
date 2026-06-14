import Foundation

/// Idioma EFETIVO em que o app está sendo exibido (respeita o override por-app
/// das Ajustes do Sistema). Usado para os nomes de pasta/arquivo seguirem a UI.
enum AppLocale {
    static var effective: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "pt-BR")
    }
}
