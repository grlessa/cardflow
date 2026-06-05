import Testing
import Foundation
@testable import OffloadKit

@Suite struct OffloadDecisionTests {
    func outcome(verified: Int = 0, failures: [String] = [], skipped: [String] = []) -> OffloadOutcome {
        OffloadOutcome(verifiedCount: verified, failures: failures, unrecognized: [], skipped: skipped)
    }

    // #10: a matriz da decisão mais sensível do app, agora testável de forma pura.
    @Test func canFormatOnlyWhenSavedSomethingAndNoFailure() {
        // salvou (verificou) e sem falha → pode formatar
        #expect(outcome(verified: 3).canSafelyFormatCard)
        // nada copiado agora, mas tudo já estava presente → também é seguro
        #expect(outcome(skipped: ["a.mp4", "b.mp4"]).canSafelyFormatCard)
        // verificou alguns MAS houve falha → NÃO pode formatar
        #expect(!outcome(verified: 3, failures: ["x.mp4"]).canSafelyFormatCard)
        // cartão vazio / filtro errado (nada salvo, nada pulado) → NÃO dá luz verde
        #expect(!outcome().canSafelyFormatCard)
        // só falha → NÃO
        #expect(!outcome(failures: ["x.mp4"]).canSafelyFormatCard)
    }
}
