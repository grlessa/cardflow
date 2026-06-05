import Testing
@testable import OffloadKit

@Suite struct CollisionResolverTests {
    let resolver = CollisionResolver()

    @Test func freePathIsUsedAsIs() {
        let existing: [String: UInt64] = [:]
        let r = resolver.resolve(desired: "E/VIDEO/C0001.mp4", sourceHash: 10,
                                 existingHash: { existing[$0] }, suffixes: ["_2026-05-28_110640"])
        #expect(r == .use("E/VIDEO/C0001.mp4"))
    }

    @Test func sameContentIsSkipped() {
        let r = resolver.resolve(desired: "E/VIDEO/C0001.mp4", sourceHash: 10,
                                 existingHash: { ["E/VIDEO/C0001.mp4": 10][$0] }, suffixes: ["_a"])
        #expect(r == .alreadyPresent("E/VIDEO/C0001.mp4"))
    }

    // Rollover: dois arquivos DIFERENTES querem o mesmo nome → o segundo é desambiguado
    // (o sufixo entra ANTES da extensão).
    @Test func differentContentSameNameIsDisambiguated() {
        let r = resolver.resolve(desired: "E/FOTO/DSC00001.jpg", sourceHash: 99,
                                 existingHash: { ["E/FOTO/DSC00001.jpg": 10][$0] },
                                 suffixes: ["_2026-05-28_110640"])
        #expect(r == .use("E/FOTO/DSC00001_2026-05-28_110640.jpg"))
    }

    @Test func disambiguationFallsThroughSuffixes() {
        // primeiro sufixo já ocupado por conteúdo diferente → tenta o próximo
        let existing: [String: UInt64] = [
            "E/FOTO/DSC00001.jpg": 10,
            "E/FOTO/DSC00001_s1.jpg": 20,
        ]
        let r = resolver.resolve(desired: "E/FOTO/DSC00001.jpg", sourceHash: 99,
                                 existingHash: { existing[$0] }, suffixes: ["_s1", "_s2"])
        #expect(r == .use("E/FOTO/DSC00001_s2.jpg"))
    }

    // #30: ÚLTIMA linha de defesa contra perda de frame — TODOS os sufixos fornecidos já estão
    // ocupados por conteúdo diferente → cai no sufixo de HASH do conteúdo (único por bytes).
    @Test func allSuffixesTakenFallsBackToHashSuffix() {
        let existing: [String: UInt64] = [
            "E/FOTO/DSC00001.jpg": 10,
            "E/FOTO/DSC00001_s1.jpg": 20,
            "E/FOTO/DSC00001_s2.jpg": 30,
        ]
        let r = resolver.resolve(desired: "E/FOTO/DSC00001.jpg", sourceHash: 0xABCD,
                                 existingHash: { existing[$0] }, suffixes: ["_s1", "_s2"])
        // hash 0xABCD em hexa = "abcd"; sufixo entra antes da extensão
        #expect(r == .use("E/FOTO/DSC00001_abcd.jpg"))
    }

    // E se o caminho do hash também já existir COM O MESMO conteúdo → pula (não duplica).
    @Test func hashSuffixPathWithSameContentIsSkipped() {
        let existing: [String: UInt64] = [
            "E/FOTO/DSC00001.jpg": 10,
            "E/FOTO/DSC00001_abcd.jpg": 0xABCD,   // já gravado antes, mesmo conteúdo
        ]
        let r = resolver.resolve(desired: "E/FOTO/DSC00001.jpg", sourceHash: 0xABCD,
                                 existingHash: { existing[$0] }, suffixes: [])
        #expect(r == .alreadyPresent("E/FOTO/DSC00001_abcd.jpg"))
    }
}
