import Foundation

/// Gera o `appcast.xml` que o Sparkle lê pra saber se há versão nova.
/// Função pura (entra dado, sai string) pra ser testável; o pipeline de release a chama
/// via o executável de build `make-appcast`. O feed tem um item só: anunciamos sempre a última versão.
public enum Appcast {
    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

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
              <title>\(xmlEscape(shortVersion))</title>
              <sparkle:version>\(xmlEscape(build))</sparkle:version>
              <sparkle:shortVersionString>\(xmlEscape(shortVersion))</sparkle:shortVersionString>
              <sparkle:minimumSystemVersion>\(xmlEscape(minimumSystemVersion))</sparkle:minimumSystemVersion>
              <pubDate>\(xmlEscape(pubDate))</pubDate>
              <description><![CDATA[\(safeNotes)]]></description>
              <enclosure url="\(xmlEscape(enclosureURL))" sparkle:edSignature="\(xmlEscape(edSignature))" length="\(length)" type="application/octet-stream" />
            </item>
          </channel>
        </rss>
        """
    }
}
