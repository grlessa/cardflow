import Testing
@testable import OffloadKit

@Test func libraryVersionIsSet() {
    // não amarra a um número (pra não quebrar a cada release): só exige x.y.z preenchido.
    let parts = OffloadKit.version.split(separator: ".")
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { Int($0) != nil })
}
