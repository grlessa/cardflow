import Testing
@testable import OffloadKit

@Suite struct TokenCatalogTests {
    /// Todo token conhecido pelo motor tem um rótulo humano — senão o picker mostraria token sem nome.
    @Test func catalogoCobreTodosOsTokensConhecidos() {
        let catalogo = Set(TokenCatalog.all.map(\.name))
        #expect(catalogo.union(NameBuilder.tokenAliases.keys) == NameBuilder.knownTokens)
        #expect(TokenCatalog.all.count + NameBuilder.tokenAliases.count == NameBuilder.knownTokens.count)
    }

    @Test func infoPorToken() {
        #expect(TokenCatalog.info(for: "projeto")?.label == "Projeto")
        #expect(TokenCatalog.info(for: "evento")?.name == "projeto")   // apelido de modelos antigos
        #expect(TokenCatalog.info(for: "contador")?.label == "Número")
        #expect(TokenCatalog.info(for: "naoexiste") == nil)
    }

    @Test func todoInfoTemRotuloCategoriaEIcone() {
        for info in TokenCatalog.all {
            #expect(!info.label.isEmpty)
            #expect(!info.category.isEmpty)
            #expect(!info.systemImage.isEmpty)
        }
    }
}
