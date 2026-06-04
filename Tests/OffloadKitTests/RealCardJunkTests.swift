import Testing
import Foundation
@testable import OffloadKit

@Suite struct RealCardJunkTests {
    private func makeCard() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rc-" + UUID().uuidString)
        let fm = FileManager.default
        func write(_ rel: String) throws {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try write("DCIM/100MSDCF/DSC00001.JPG")
        try write("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        try write(".Spotlight-V100/Store-V2/abc/store.db")   // dir oculto do macOS
        try write(".fseventsd/0000000000")                   // dir oculto do macOS
        try write("AVF_INFO/AVIN0001.BNP")                    // gestão Sony
        try write("PRIVATE/SONY/SONYCARD.IND")               // gestão Sony
        try write("PRIVATE/DATABASE/DATABASE.BIN")           // gestão Sony
        try write("PRIVATE/M4ROOT/GENERAL/LUT/look.cube")    // LUT → sidecar
        try write("MISC/leia.txt")                            // genuinamente desconhecido
        return root
    }

    @Test func skipsSystemDirsAndClassifiesManagementFiles() throws {
        let root = try makeCard()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try CardScanner(classifier: FileClassifier(preset: .sampleConferencia)).scan(cardRoot: root)

        // diretórios ocultos do macOS nem aparecem
        #expect(files.allSatisfy { !$0.relPath.contains(".Spotlight-V100") && !$0.relPath.contains(".fseventsd") })

        let byType = Dictionary(grouping: files, by: \.type).mapValues(\.count)
        #expect(byType[.photo] == 1)
        #expect(byType[.video] == 1)
        // gestão Sony (.BNP/.IND/.BIN) classificada como junk, não unknown
        #expect((byType[.junk] ?? 0) >= 3)
        #expect(byType[.sidecar] == 1)        // o .cube
        // a rede de segurança só pega o leia.txt
        #expect(files.filter { $0.type == .unknown }.map(\.relPath) == ["MISC/leia.txt"])
    }
}
