import Testing
import Foundation
@testable import OffloadKit

@Suite struct NameBuilderTests {
    let tz = TimeZone(identifier: "America/Sao_Paulo")!  // 1_780_000_000 = 2026-05-28 17:26:40 -03

    @Test func loteTokenRenderizaLoteComDoisDigitos() throws {
        var preset = Preset.flatDefault
        preset.folderStructure = "{evento}/{lote}/{tipo}"
        let nb = NameBuilder(preset: preset, timeZone: tz)
        let f = MediaFile(sourceURL: URL(fileURLWithPath: "/c/clip.mov"), relPath: "clip.mov",
                          size: 1, type: .video, captureDate: Date(timeIntervalSince1970: 1_780_000_000))
        let dest = try nb.relativeDestination(for: f, context: .init(camera: "Cam", counter: 1, lote: 3))
        #expect(dest.contains("/Lote 03/"))
    }

    func file(type: FileType, rel: String) -> MediaFile {
        MediaFile(sourceURL: URL(fileURLWithPath: "/card/\(rel)"), relPath: rel, size: 100,
                  type: type, captureDate: Date(timeIntervalSince1970: 1_780_000_000))
    }
    func ctx(camera: String = "Cam01", counter: Int = 1, card: String = "SONY", session: [String: String] = [:]) -> NamingContext {
        NamingContext(camera: camera, counter: counter, cardName: card, sessionValues: session)
    }

    @Test func structureWithoutRenameKeepsOriginalName() throws {
        let nb = NameBuilder(preset: .sampleConferencia, timeZone: tz)
        let rel = try nb.relativeDestination(for: file(type: .video, rel: "DCIM/X/C0001.MP4"), context: ctx())
        #expect(rel == "Conferencia-Junho-2026/Video/C0001.MP4")
    }

    @Test(arguments: [
        ("{ano}", "2026"),
        ("{ano2}", "26"),
        ("{mes}", "05"),
        ("{dia}", "28"),
        ("{horas}", "17"),
        ("{minutos}", "26"),
        ("{segundos}", "40"),
        ("{ano}-{mes}", "2026-05"),
        ("{dia}-{mes}-{ano}", "28-05-2026"),
        ("{hora}", "172640"),
        ("{ext}", "JPG"),
        ("{cartao}", "SONY"),
        ("{pasta_origem}", "20260528"),
        ("{nome_original}", "DSC00001"),
    ])
    func componentTokens(template: String, expected: String) throws {
        var preset = Preset.sampleConferencia
        preset.rename = .init(enabled: true, template: template, counterPadding: 4)
        preset.folderStructure = "X"
        let nb = NameBuilder(preset: preset, timeZone: tz)
        let rel = try nb.relativeDestination(for: file(type: .photo, rel: "DCIM/20260528/DSC00001.JPG"), context: ctx())
        #expect(rel == "X/\(expected).JPG")
    }

    @Test func monthNamesAreCleanAndCapitalized() throws {
        var preset = Preset.sampleConferencia
        preset.locale = "pt_BR"
        preset.rename = .init(enabled: true, template: "{mes_abrev}_{mes_nome}", counterPadding: 4)
        preset.folderStructure = "X"
        let nb = NameBuilder(preset: preset, timeZone: tz)
        let rel = try nb.relativeDestination(for: file(type: .photo, rel: "a/DSC1.JPG"), context: ctx())
        // maio em pt-BR; abreviado sem ponto e capitalizado
        #expect(rel == "X/Mai_Maio.JPG")
    }

    @Test func counterStartStepAndPadding() throws {
        var preset = Preset.sampleConferencia
        preset.rename = .init(enabled: true, template: "{contador}", counterPadding: 4, counterStart: 10, counterStep: 5)
        preset.folderStructure = "X"
        let nb = NameBuilder(preset: preset, timeZone: tz)
        let r1 = try nb.relativeDestination(for: file(type: .photo, rel: "a/1.JPG"), context: ctx(counter: 1))
        let r3 = try nb.relativeDestination(for: file(type: .photo, rel: "a/3.JPG"), context: ctx(counter: 3))
        #expect(r1 == "X/0010.JPG")     // 10 + 0*5
        #expect(r3 == "X/0020.JPG")     // 10 + 2*5
    }

    @Test func caseModifiers() throws {
        var preset = Preset.sampleConferencia
        preset.rename = .init(enabled: true, template: "{nome_original:minuscula}_{evento:maiuscula}", counterPadding: 4)
        preset.folderStructure = "X"
        let nb = NameBuilder(preset: preset, timeZone: tz)
        let rel = try nb.relativeDestination(for: file(type: .photo, rel: "a/DSC00001.JPG"), context: ctx())
        #expect(rel == "X/dsc00001_CONFERENCIA-JUNHO-2026.JPG")
    }

    @Test func customSessionFieldResolves() throws {
        var preset = Preset.sampleConferencia
        preset.sessionFields = [.init(key: "operador", label: "Operador")]
        preset.rename = .init(enabled: true, template: "{operador}_{nome_original}", counterPadding: 4)
        preset.folderStructure = "X"
        let nb = NameBuilder(preset: preset, timeZone: tz)
        let rel = try nb.relativeDestination(for: file(type: .photo, rel: "a/DSC1.JPG"),
                                             context: ctx(session: ["operador": "Joao"]))
        #expect(rel == "X/Joao_DSC1.JPG")
    }

    @Test func unknownTokenThrows() {
        var preset = Preset.sampleConferencia
        preset.rename = .init(enabled: true, template: "{operdor}", counterPadding: 4)
        let nb = NameBuilder(preset: preset, timeZone: tz)
        #expect(throws: NamingError.self) {
            _ = try nb.relativeDestination(for: file(type: .photo, rel: "a/x.JPG"), context: ctx())
        }
    }

    @Test func unknownModifierThrows() {
        var preset = Preset.sampleConferencia
        preset.rename = .init(enabled: true, template: "{evento:gritar}", counterPadding: 4)
        let nb = NameBuilder(preset: preset, timeZone: tz)
        #expect(throws: NamingError.self) {
            _ = try nb.relativeDestination(for: file(type: .photo, rel: "a/x.JPG"), context: ctx())
        }
    }

    @Test func tokenValuesComBarraNaoCriamSubpastaAcidental() throws {
        // Voluntário digita "Culto 09/06" no campo Pasta → a barra NÃO pode virar subpasta.
        var preset = Preset.sampleConferencia
        preset.evento = "Culto 09/06"
        preset.folderStructure = "{evento}/{tipo}"
        preset.rename.enabled = false
        let nb = NameBuilder(preset: preset, timeZone: tz)
        let rel = try nb.relativeDestination(for: file(type: .photo, rel: "a/DSC1.JPG"), context: ctx())
        // a "/" do template (entre {evento} e {tipo}) fica; a "/" do VALOR vira "-"
        #expect(rel == "Culto 09-06/Foto/DSC1.JPG")
    }

    @Test func dataComFormatoDeBarraNaoQuebraOCaminho() throws {
        var preset = Preset.sampleConferencia
        preset.dateFormat = "yyyy/MM/dd"
        preset.rename = .init(enabled: true, template: "{data}_{nome_original}", counterPadding: 4)
        preset.folderStructure = "X"
        let nb = NameBuilder(preset: preset, timeZone: tz)
        let rel = try nb.relativeDestination(for: file(type: .photo, rel: "a/DSC1.JPG"), context: ctx())
        #expect(rel == "X/2026-05-28_DSC1.JPG")   // sem barras no nome do arquivo
    }

    @Test func doisPontosNoValorViramTraco() throws {
        // ":" é separador legado no macOS — também sanitiza.
        var preset = Preset.sampleConferencia
        preset.sessionFields = [.init(key: "horario", label: "Horário")]
        preset.rename = .init(enabled: true, template: "{horario}_{nome_original}", counterPadding: 4)
        preset.folderStructure = "X"
        let nb = NameBuilder(preset: preset, timeZone: tz)
        let rel = try nb.relativeDestination(for: file(type: .photo, rel: "a/DSC1.JPG"),
                                             context: ctx(session: ["horario": "14:30"]))
        #expect(rel == "X/14-30_DSC1.JPG")
    }

    @Test func staticValidationCatchesUnknownToken() {
        #expect(throws: NamingError.self) {
            try NameBuilder.validateTokensExist(in: "{evento}/{naoexiste}", knownSessionKeys: [])
        }
        // token de sessão declarado passa
        #expect(throws: Never.self) {
            try NameBuilder.validateTokensExist(in: "{evento}/{operador}", knownSessionKeys: ["operador"])
        }
    }

    // MARK: - Segurança: path traversal

    @Test func sanitizeNeutralizesTraversalDots() {
        #expect(NameBuilder.sanitizePathComponent("..") == "__")
        #expect(NameBuilder.sanitizePathComponent(".") == "_")
        #expect(NameBuilder.sanitizePathComponent("a/b") == "a-b")
        #expect(NameBuilder.sanitizePathComponent("..foto") == "..foto")   // só "." e ".." exatos viram seguro
    }

    @Test func validateNoTraversalRejectsEscapes() {
        #expect(throws: NamingError.self) { try NameBuilder.validateNoTraversal(in: "../{evento}/{tipo}") }
        #expect(throws: NamingError.self) { try NameBuilder.validateNoTraversal(in: "{evento}/../{tipo}") }
        #expect(throws: NamingError.self) { try NameBuilder.validateNoTraversal(in: "/etc/{evento}") }
        #expect(throws: NamingError.self) { try NameBuilder.validateNoTraversal(in: "~/{evento}") }
        // legítimos NÃO lançam
        #expect(throws: Never.self) { try NameBuilder.validateNoTraversal(in: "{evento}/{dia} {mes_abrev} {ano}/{tipo}") }
        #expect(throws: Never.self) { try NameBuilder.validateNoTraversal(in: "..foto/{tipo}") }   // "..foto" não é travessia
    }

    @Test func horaUsaTimeFormatDoPreset() throws {
        var p = Preset.flatDefault
        p.rename = .init(enabled: true, template: "{hora}", counterPadding: 4)
        p.timeFormat = "HH'h'mm"
        let nb = NameBuilder(preset: p, timeZone: TimeZone(identifier: "America/Sao_Paulo")!)
        let file = MediaFile(sourceURL: URL(fileURLWithPath: "/c/x.jpg"), relPath: "x.jpg",
                             size: 1, type: .photo, captureDate: Date(timeIntervalSince1970: 1_780_000_000))
        let rel = try nb.relativeDestination(for: file, camera: "Cam", counter: 1)
        #expect(rel.contains("17h26"))   // captureDate = 2026-05-28 17:26:40 -03
    }

    @Test func dataRenderizaMesEmPortugues() throws {
        var p = Preset.flatDefault
        p.rename = .init(enabled: true, template: "{data}", counterPadding: 4)
        p.dateFormat = "dd 'de' MMMM 'de' yyyy"; p.locale = "pt_BR"
        let nb = NameBuilder(preset: p, timeZone: TimeZone(identifier: "America/Sao_Paulo")!)
        let file = MediaFile(sourceURL: URL(fileURLWithPath: "/c/x.jpg"), relPath: "x.jpg",
                             size: 1, type: .photo, captureDate: Date(timeIntervalSince1970: 1_780_000_000))
        let rel = try nb.relativeDestination(for: file, camera: "Cam", counter: 1)
        #expect(rel.lowercased().contains("maio"))   // mês em pt-BR, não "May"
    }

    @Test func tokenValueCannotIntroduceTraversal() throws {
        var p = Preset.flatDefault
        p.evento = ".."   // tentativa de usar o valor de um token como ".."
        let nb = NameBuilder(preset: p)
        let file = MediaFile(sourceURL: URL(fileURLWithPath: "/c/x.jpg"), relPath: "x.jpg",
                             size: 1, type: .photo, captureDate: Date(timeIntervalSince1970: 1_780_000_000))
        let rel = try nb.relativeDestination(for: file, camera: "Cam", counter: 1)
        #expect(!rel.contains("/../"))
        #expect(!rel.hasPrefix("../"))
        #expect(rel.hasPrefix("__/"))   // ".." virou "__"
    }

    // #7: template que renderiza VAZIO não pode gerar ".JPG" (oculto). Cai pro nome original.
    @Test func emptyRenderedStemFallsBackToOriginalName() throws {
        var p = Preset.flatDefault
        p.evento = ""
        p.folderStructure = "fixo"
        p.rename = .init(enabled: true, template: "{evento}", counterPadding: 4)   // renderiza vazio
        let nb = NameBuilder(preset: p, timeZone: tz)
        let rel = try nb.relativeDestination(for: file(type: .photo, rel: "DCIM/100/DSC00001.JPG"), context: ctx())
        let fileName = (rel as NSString).lastPathComponent
        #expect(!fileName.hasPrefix("."))          // NÃO é oculto
        #expect(fileName == "DSC00001.JPG")        // caiu pro nome original
    }

    // #7b: template só com separadores também é "vazio na prática" → cai pro original.
    @Test func separatorsOnlyStemFallsBackToOriginalName() throws {
        var p = Preset.flatDefault
        p.evento = ""
        p.folderStructure = "fixo"
        p.rename = .init(enabled: true, template: "{evento}_-_{evento}", counterPadding: 4)
        let nb = NameBuilder(preset: p, timeZone: tz)
        let rel = try nb.relativeDestination(for: file(type: .photo, rel: "DCIM/100/IMG_9.JPG"), context: ctx())
        #expect((rel as NSString).lastPathComponent == "IMG_9.JPG")
    }

    // #8: nome de evento gigante (acentos pt-BR custam 2-3 bytes) não pode estourar o limite do FS.
    @Test func overlongComponentIsTruncatedKeepingExtension() throws {
        var p = Preset.flatDefault
        p.evento = String(repeating: "é", count: 300)   // ~600 bytes UTF-8
        p.folderStructure = "{evento}"
        p.rename = .init(enabled: true, template: "{evento}", counterPadding: 4)
        let nb = NameBuilder(preset: p, timeZone: tz)
        let rel = try nb.relativeDestination(for: file(type: .photo, rel: "DCIM/100/DSC1.JPG"), context: ctx())
        for comp in rel.split(separator: "/") {
            #expect(String(comp).utf8.count <= 255)   // cabe no limite do APFS
        }
        #expect((rel as NSString).pathExtension == "JPG")   // extensão preservada
    }

    // #26: caracteres de controle são removidos e o valor é normalizado pra NFC.
    @Test func sanitizeStripsControlCharsAndNormalizesNFC() {
        let cleaned = NameBuilder.sanitizePathComponent("Cul\tto\n09\r")
        #expect(cleaned == "Culto09")
        let nfd = "Cafe\u{301}"   // "Café" decomposto (NFD)
        let nfc = NameBuilder.sanitizePathComponent(nfd)
        #expect(nfc == "Café")
        #expect(nfc.unicodeScalars.count == 4)   // C a f é(precomposto)
    }
}
