import Testing
import Foundation
@testable import OffloadKit

@Suite struct FormattingTests {
    // #31: tamanho em base DECIMAL (1000), igual ao Finder — antes a CLI usava 1024 e divergia do app.
    @Test func humanBytesIsDecimal() {
        #expect(Format.humanBytes(0) == "0 B")
        #expect(Format.humanBytes(999) == "999 B")
        #expect(Format.humanBytes(1_000) == "1.0 KB")
        #expect(Format.humanBytes(1_000_000) == "1.0 MB")
        #expect(Format.humanBytes(76_050_000_000) == "76.0 GB")   // o que o Finder mostra
    }

    @Test func elapsedIsHumanPtBr() {
        #expect(Format.elapsed(45) == "45 s")
        #expect(Format.elapsed(60) == "1 min")
        #expect(Format.elapsed(17 * 60 + 12) == "17 min 12 s")
        #expect(Format.elapsed(3600) == "1 h")
        #expect(Format.elapsed(3600 + 17 * 60) == "1 h 17 min")
    }
}
