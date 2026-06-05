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

    // MARK: - Níveis de pasta (construtor por linhas)

    @Test func levelsSeparaPastasPorBarra() {
        let lvls = TemplateTokenizer.levels(from: "{evento}/{dia} {mes_abrev} {ano}/{tipo}")
        #expect(lvls.count == 3)
        #expect(lvls[0] == [.token(name: "evento", modifiers: [])])
        #expect(lvls[2] == [.token(name: "tipo", modifiers: [])])
        #expect(lvls[1] == [.token(name: "dia", modifiers: []), .literal(" "),
                            .token(name: "mes_abrev", modifiers: []), .literal(" "),
                            .token(name: "ano", modifiers: [])])
    }

    @Test func joinLevelsReconstroiEPulaVazios() {
        let lvls = TemplateTokenizer.levels(from: "{evento}/{dia} {mes_abrev} {ano}/{tipo}")
        #expect(TemplateTokenizer.joinLevels(lvls) == "{evento}/{dia} {mes_abrev} {ano}/{tipo}")
        // nível vazio (pasta recém-criada, sem peça) não vira "//" no template
        let comVazio = lvls + [[]]
        #expect(TemplateTokenizer.joinLevels(comVazio) == "{evento}/{dia} {mes_abrev} {ano}/{tipo}")
    }

    @Test func levelsRoundTripComTextoLivre() {
        let t = "{evento}/Culto {dia}/{tipo}"
        #expect(TemplateTokenizer.joinLevels(TemplateTokenizer.levels(from: t)) == t)
    }
}
