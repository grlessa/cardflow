import Foundation

public extension OffloadOutcome {
    /// O cartão pode ser ejetado/formatado com segurança?
    ///
    /// Só quando NADA falhou E algo foi de fato salvo (verificado agora OU já estava presente).
    /// Um cartão vazio, ou um filtro errado que não copiou nada, NÃO dá luz verde — senão o
    /// operador formataria um cartão cujo conteúdo não foi pra lugar nenhum.
    ///
    /// Esta é a decisão mais sensível do app, então é ÚNICA: a ejeção automática (AppModel), o
    /// veredito "Pode formatar" e o badge de resultado (MainView) chamam todos esta mesma função,
    /// pra a UI nunca dar luz verde divergindo do que o motor realmente faz.
    var canSafelyFormatCard: Bool {
        failures.isEmpty && (verifiedCount > 0 || !skipped.isEmpty)
    }
}
