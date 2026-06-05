import Testing
import Foundation
@testable import OffloadKit

@Suite struct CardScannerTests {
    @Test func scansAndClassifiesEveryFile() throws {
        let card = try FakeCard()
        defer { card.cleanup() }

        let scanner = CardScanner(classifier: FileClassifier(preset: .sampleConferencia))
        let files = try scanner.scan(cardRoot: card.root)

        let byType = Dictionary(grouping: files, by: \.type).mapValues(\.count)
        #expect(byType[.photo] == 2)
        #expect(byType[.video] == 1)
        #expect(byType[.sidecar] == 1)
        #expect(byType[.junk] == 1)
        #expect(byType[.unknown] == 1)

        let video = try #require(files.first { $0.type == .video })
        #expect(video.relPath == "PRIVATE/M4ROOT/CLIP/C0001.MP4")
        #expect(video.size == 4096)
        #expect(video.captureDate == Date(timeIntervalSince1970: 1_780_000_000 + 120))
    }

    @Test func scanAnotaPreserveEmArvoreDeCinemaMista() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-cine-" + UUID().uuidString)
        let fm = FileManager.default
        func write(_ rel: String) throws {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        defer { try? fm.removeItem(at: root) }
        try write("DCIM/100MSDCF/DSC0001.JPG")                       // plano
        try write("A001.RDM/A001_C001.RDC/A001_C001_001.R3D")        // cinema
        try write("A001.RDM/A001_C001.RDC/A001_C001.RMD")            // irmão
        try write("clip.braw"); try write("clip.sidecar")           // grupo solto

        let files = try CardScanner(classifier: FileClassifier(preset: .factoryDefault)).scan(cardRoot: root)
        func preserve(_ rel: String) -> Bool { files.first { $0.relPath == rel }?.preserve ?? false }

        #expect(preserve("A001.RDM/A001_C001.RDC/A001_C001_001.R3D"))
        #expect(preserve("A001.RDM/A001_C001.RDC/A001_C001.RMD"))   // irmão preservado
        #expect(preserve("clip.braw") && preserve("clip.sidecar"))
        #expect(!preserve("DCIM/100MSDCF/DSC0001.JPG"))             // plano
    }

    // #13: data de captura usa criação > modificação > fallback estável (NÃO 1970).
    @Test func resolveCaptureFallsBackStablyNotEpoch() {
        let creation = Date(timeIntervalSince1970: 2000)
        let modification = Date(timeIntervalSince1970: 1000)
        let fallback = Date(timeIntervalSince1970: 5000)
        #expect(CardScanner.resolveCapture(creation: creation, modification: modification, fallback: fallback) == creation)
        #expect(CardScanner.resolveCapture(creation: nil, modification: modification, fallback: fallback) == modification)
        #expect(CardScanner.resolveCapture(creation: nil, modification: nil, fallback: fallback) == fallback)
        // a regressão de #13: sem data do arquivo, NÃO cai em 1970 (footage de hoje em pasta "jan 1970")
        #expect(CardScanner.resolveCapture(creation: nil, modification: nil, fallback: fallback) != Date(timeIntervalSince1970: 0))
    }
}
