import Testing
import Foundation
@testable import OffloadKit

@Suite struct PresetStoreTests {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func factoryDefaultIsValid() throws {
        try PresetStore.validate(.factoryDefault)
        #expect(Preset.factoryDefault.id == "factory-default")
    }

    @Test func factoryDefaultIsPtBrByDate() throws {
        let p = Preset.factoryDefault
        #expect(p.evento == "Sessão")
        #expect(p.folderStructure == "{evento}/{dia} {mes_abrev} {ano}/{tipo}")
        try PresetStore.validate(p)   // tokens {dia}{mes_abrev}{ano} são válidos
        // render determinístico com captureDate fixo → "Gravações/<data pt-BR>/VIDEO/clip.mov"
        let file = MediaFile(sourceURL: URL(fileURLWithPath: "/c/clip.mov"), relPath: "clip.mov",
                             size: 1, type: .video, captureDate: Date(timeIntervalSince1970: 1_780_000_000))
        let nb = NameBuilder(preset: p, timeZone: TimeZone(identifier: "America/Sao_Paulo")!)
        let dest = try nb.relativeDestination(for: file, context: .init(camera: "Cam", counter: 1))
        #expect(dest.hasPrefix("Sessão/"))
        #expect(dest.contains("/VIDEO/clip.mov"))
        #expect(dest.split(separator: "/")[1].contains("2026"))   // subpasta de data tem o ano
    }

    @Test func duplicatedGetsNewIdKeepsRest() {
        let orig = Preset.factoryDefault
        let dup = orig.duplicated(newName: "Cópia X")
        #expect(dup.id != orig.id)
        #expect(dup.name == "Cópia X")
        #expect(dup.evento == orig.evento)
        #expect(dup.folderStructure == orig.folderStructure)
    }

    @Test func saveThenListAndLoadRoundTrips() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = PresetStore(directory: dir)
        var p = Preset.factoryDefault
        p.id = "meu-evento"; p.name = "Meu Evento"; p.evento = "Meu-Evento"
        let url = try store.save(p)
        #expect(url.pathExtension == "cfp")

        let listed = try store.list()
        #expect(listed.count == 1)
        #expect(listed.first?.id == "meu-evento")
        #expect(try store.load(from: url) == p)
    }

    @Test func rejectsUnsupportedSchema() {
        var p = Preset.factoryDefault
        p.schemaVersion = 99
        #expect(throws: PresetStore.PresetError.self) { try PresetStore.validate(p) }
    }

    /// Template de nome inválido NÃO bloqueia salvar quando o renome está desligado (não é usado).
    @Test func templateDeNomeInvalidoSoBloqueiaComRenomeLigado() {
        var p = Preset.factoryDefault
        p.rename.template = "{tokeninvalido}"
        p.rename.enabled = false
        #expect(throws: Never.self) { try PresetStore.validate(p) }   // renome off → não cobra
        p.rename.enabled = true
        #expect(throws: PresetStore.PresetError.self) { try PresetStore.validate(p) }   // renome on → cobra
    }

    @Test func rejectsUnknownTokenInFolderStructure() {
        var p = Preset.factoryDefault
        p.folderStructure = "{evento}/{naoexiste}"
        #expect(throws: PresetStore.PresetError.self) { try PresetStore.validate(p) }
    }

    @Test func acceptsDeclaredSessionFieldInTemplate() throws {
        var p = Preset.factoryDefault
        p.sessionFields = [.init(key: "operador", label: "Operador")]
        p.rename = .init(enabled: true, template: "{operador}_{nome_original}", counterPadding: 4)
        try PresetStore.validate(p)   // não lança
    }

    @Test func appPresetsDirectoryHasExpectedSuffix() {
        #expect(PresetStore.appPresetsDirectory().path.hasSuffix("Cardflow/presets"))
    }

    // MARK: - Segurança: validação rejeita preset malicioso

    @Test func validateRejectsPathTraversalInFolderStructure() {
        var p = Preset.flatDefault
        p.folderStructure = "../ESCAPE/{tipo}"
        #expect(throws: PresetStore.PresetError.self) { try PresetStore.validate(p) }
    }

    @Test func validateRejectsAbsoluteFolderStructure() {
        var p = Preset.flatDefault
        p.folderStructure = "/tmp/EVIL/{tipo}"
        #expect(throws: PresetStore.PresetError.self) { try PresetStore.validate(p) }
    }

    @Test func validateRejectsTraversalInRenameTemplate() {
        var p = Preset.flatDefault
        p.rename.enabled = true
        p.rename.template = "../{nome_original}"
        #expect(throws: PresetStore.PresetError.self) { try PresetStore.validate(p) }
    }

    @Test func validateRejectsUnsafeId() {
        var p = Preset.flatDefault
        p.id = "../../evil"
        #expect(throws: PresetStore.PresetError.self) { try PresetStore.validate(p) }
    }
}
