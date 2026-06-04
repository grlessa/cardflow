import Testing
@testable import OffloadKit

@Test func libraryVersionIsSet() {
    #expect(OffloadKit.version == "0.1.0")
}
