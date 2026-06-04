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
}
