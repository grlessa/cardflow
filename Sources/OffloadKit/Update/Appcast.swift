import Foundation

/// Gera o `appcast.xml` que o Sparkle lê pra saber se há versão nova.
/// Função pura (entra dado, sai string) pra ser testável; o pipeline de release a chama
/// via o executável de build `make-appcast`. O feed tem um item só: anunciamos sempre a última versão.
public enum Appcast {
    /// `releaseNotesHTML` vai dentro de um bloco CDATA. Um eventual "]]>" cru é dividido
    /// no truque padrão pra não fechar o CDATA antes da hora.
    public static func xml(shortVersion: String,
                           build: String,
                           minimumSystemVersion: String,
                           enclosureURL: String,
                           edSignature: String,
                           length: Int,
                           pubDate: String,
                           releaseNotesHTML: String) -> String {
        let safeNotes = releaseNotesHTML.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
        return """
        <?xml version="1.0" standalone="yes"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
          <channel>
            <title>Cardflow</title>
            <item>
              <title>\(shortVersion)</title>
              <sparkle:version>\(build)</sparkle:version>
              <sparkle:shortVersionString>\(shortVersion)</sparkle:shortVersionString>
              <sparkle:minimumSystemVersion>\(minimumSystemVersion)</sparkle:minimumSystemVersion>
              <pubDate>\(pubDate)</pubDate>
              <description><![CDATA[\(safeNotes)]]></description>
              <enclosure url="\(enclosureURL)" sparkle:edSignature="\(edSignature)" length="\(length)" type="application/octet-stream" />
            </item>
          </channel>
        </rss>
        """
    }
}
