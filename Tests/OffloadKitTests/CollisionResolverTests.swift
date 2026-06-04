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
}
