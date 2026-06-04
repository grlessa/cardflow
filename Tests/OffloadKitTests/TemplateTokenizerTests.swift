import Testing
@testable import OffloadKit

@Suite struct TemplateTokenizerTests {
    @Test func parseBasicoSeparaTokensELiterais() {
        let segs = TemplateTokenizer.parse("{evento}_{contador}")
        #expect(segs == [
            .token(name: "evento", modifiers: []),
            .literal("_"),
            .token(name: "contador", modifiers: []),
        ])
    }

    @Test func parseModificadores() {
        #expect(TemplateTokenizer.parse("{evento:maiuscula}") == [.token(name: "evento", modifiers: ["maiuscula"])])
    }

    @Test func parseLiteralPuroETokensConsecutivos() {
        #expect(TemplateTokenizer.parse("abc") == [.literal("abc")])
        #expect(TemplateTokenizer.parse("{a}{b}") == [.token(name: "a", modifiers: []), .token(name: "b", modifiers: [])])
    }

    @Test func parseVazioEChaveSemFechar() {
        #expect(TemplateTokenizer.parse("") == [])
        #expect(TemplateTokenizer.parse("{abc") == [.literal("{abc")])
    }

    @Test func serializeReconstroiTemplate() {
        let segs: [TemplateSegment] = [.token(name: "evento", modifiers: ["maiuscula"]), .literal("_"), .token(name: "contador", modifiers: [])]
        #expect(TemplateTokenizer.serialize(segs) == "{evento:maiuscula}_{contador}")
    }

    @Test(arguments: ["", "abc", "{evento}_{contador}", "{evento:maiuscula}", "{a}{b}", "{evento}/{tipo}", "x{data}y"])
    func roundTripPreservaTemplate(template: String) {
        #expect(TemplateTokenizer.serialize(TemplateTokenizer.parse(template)) == template)
    }

    /// Regressão (dataloss): sufixo de texto livre ("_final") NÃO pode ser apagado como separador.
    @Test func tidyPreservaTextoLivreERemoveSeparadores() {
        let segs: [TemplateSegment] = [.token(name: "evento", modifiers: []), .literal("_"), .literal("_final"), .literal("/")]
        #expect(TemplateTokenizer.tidySeparators(segs) == [.token(name: "evento", modifiers: []), .literal("_"), .literal("_final")])
    }

    @Test func tidyRemoveBordaEColapsaDuplicados() {
        let segs: [TemplateSegment] = [.literal("_"), .token(name: "a", modifiers: []), .literal("_"), .literal("-"), .token(name: "b", modifiers: []), .literal("/")]
        #expect(TemplateTokenizer.tidySeparators(segs) == [.token(name: "a", modifiers: []), .literal("_"), .token(name: "b", modifiers: [])])
    }

    /// Remover o token do meio de "{evento}_{camera}_final" preserva o sufixo do usuário.
    @Test func tidyAposRemoverTokenDoMeioPreservaSufixo() {
        // simula segments após remover a pill "camera" de [evento, "_", camera, "_final"]
        let segs: [TemplateSegment] = [.token(name: "evento", modifiers: []), .literal("_"), .literal("_final")]
        let tidy = TemplateTokenizer.tidySeparators(segs)
        #expect(tidy.contains(.literal("_final")))   // sufixo NÃO some
    }
}
