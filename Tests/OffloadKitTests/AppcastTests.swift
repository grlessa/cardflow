import XCTest
@testable import OffloadKit

final class AppcastTests: XCTestCase {
    func test_xml_tem_os_campos_obrigatorios() {
        let xml = Appcast.xml(
            shortVersion: "0.2.0", build: "42", minimumSystemVersion: "14.0",
            enclosureURL: "https://example.com/Cardflow.dmg",
            edSignature: "SIG==", length: 12345,
            pubDate: "Thu, 11 Jun 2026 12:00:00 +0000",
            releaseNotesHTML: "<p>Correções.</p>")
        XCTAssertTrue(xml.contains("<sparkle:version>42</sparkle:version>"))
        XCTAssertTrue(xml.contains("<sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>"))
        XCTAssertTrue(xml.contains("<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>"))
        XCTAssertTrue(xml.contains(#"url="https://example.com/Cardflow.dmg""#))
        XCTAssertTrue(xml.contains(#"sparkle:edSignature="SIG==""#))
        XCTAssertTrue(xml.contains(#"length="12345""#))
        XCTAssertTrue(xml.contains("<![CDATA[<p>Correções.</p>]]>"))
    }

    func test_xml_escapa_terminador_de_cdata_nas_notas() {
        let xml = Appcast.xml(
            shortVersion: "1", build: "1", minimumSystemVersion: "14.0",
            enclosureURL: "u", edSignature: "s", length: 1, pubDate: "p",
            releaseNotesHTML: "antes]]>depois")
        XCTAssertFalse(xml.contains("antes]]>depois"))
        XCTAssertTrue(xml.contains("]]]]><![CDATA[>"))
    }
}
