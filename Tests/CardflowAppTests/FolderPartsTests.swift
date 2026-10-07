import Testing
import OffloadKit
@testable import CardflowApp

/// Pasta como frase: peças e textos, com o que vai entre eles. Ida e volta sem perder nada.
@Suite struct FolderPartsTests {
    private func t(_ n: String) -> TemplateSegment { .token(name: n, modifiers: []) }

    @Test func dataComEspacoVoltaIgual() {
        let segs: [TemplateSegment] = [t("dia"), .literal(" "), t("mes_abrev"), .literal(" "), t("ano")]
        let p = FolderParts(segs)
        #expect(p.items.count == 3 && p.separator == " ")
        #expect(p.segments == segs)
    }

    @Test func textoFixoEntraComoItem() {
        let segs: [TemplateSegment] = [.literal("Culto"), .literal(" "), t("dia")]
        let p = FolderParts(segs)
        #expect(p.items == [.text("Culto"), .token("dia", [])])
        #expect(p.segments == segs)
    }

    @Test func trocarSeparadorRefazTudo() {
        var p = FolderParts([t("ano"), .literal("-"), t("mes"), .literal("-"), t("dia")])
        #expect(p.separator == "-")
        p.separator = "_"
        #expect(p.segments == [t("ano"), .literal("_"), t("mes"), .literal("_"), t("dia")])
        p.separator = ""
        #expect(p.segments == [t("ano"), t("mes"), t("dia")])
    }

    @Test func pecasColadasTemSeparadorVazio() {
        let p = FolderParts([t("ano"), t("mes")])
        #expect(p.separator == "")
    }

    @Test func formatosProntosSaoValidos() {
        for f in FolderFormats.date + FolderFormats.other(fields: []) {
            #expect(FolderParts(f.segments).segments == f.segments, "\(f.id) não volta igual")
        }
    }
}
