import Testing
@testable import OffloadKit

@Suite struct UpdateCheckerTests {
    @Test func detectsNewerVersions() {
        #expect(UpdateChecker.isNewer("v0.2.0", than: "0.1.0"))
        #expect(UpdateChecker.isNewer("0.1.1", than: "0.1.0"))
        #expect(UpdateChecker.isNewer("1.0.0", than: "0.9.9"))
        #expect(UpdateChecker.isNewer("0.10.0", than: "0.9.0"))   // numérico, não lexical (10 > 9)
        #expect(UpdateChecker.isNewer("v1.2.0", than: "v1.1.9"))
    }

    @Test func ignoresSameOrOlder() {
        #expect(!UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        #expect(!UpdateChecker.isNewer("v0.1.0", than: "0.1.0"))   // mesmo, só com "v"
        #expect(!UpdateChecker.isNewer("0.1.0", than: "0.2.0"))
        #expect(!UpdateChecker.isNewer("0.0.9", than: "0.1.0"))
        #expect(!UpdateChecker.isNewer("0.9.0", than: "0.10.0"))
    }

    // #32: a URL de download só vale se for https em github.com — um JSON adulterado não abre
    // file:// nem outro host pelo botão "Baixar".
    @Test func onlyAcceptsHttpsGithubDownloadURL() {
        #expect(UpdateChecker.validDownloadURL("https://github.com/grlessa/cardflow/releases/tag/v0.2.0") != nil)
        #expect(UpdateChecker.validDownloadURL("https://api.github.com/x") != nil)   // subdomínio github.com
        #expect(UpdateChecker.validDownloadURL("file:///etc/passwd") == nil)
        #expect(UpdateChecker.validDownloadURL("http://github.com/x") == nil)        // não-https
        #expect(UpdateChecker.validDownloadURL("https://evil.com/x") == nil)         // outro host
    }
}
