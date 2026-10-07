import Foundation
@testable import CardflowApp
@testable import OffloadKit

extension AppModel {
    /// Modelo com um cartão de teste já lido e pronto (sem disco de verdade nem leitura em segundo plano).
    static func withTestCard(formatter: CardFormatting? = nil, name: String = "TESTCARD") -> AppModel {
        let m = AppModel(formatter: formatter)
        let card = CardSession(volume: ExternalVolume(url: URL(fileURLWithPath: "/Volumes/\(name)"), name: name,
                                                      isRemovable: true, isInternal: false))
        card.scanned = []
        card.phase = .ready
        m.cards = [card]
        return m
    }
}
