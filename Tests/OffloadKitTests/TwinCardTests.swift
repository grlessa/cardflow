import Testing
import Foundation
@testable import OffloadKit

/// Duas câmeras iguais no mesmo evento: o mesmo nome de arquivo, o mesmo tamanho (RAW sem compressão)
/// e o mesmo segundo, mas conteúdo diferente. O registro de um cartão nunca pode valer pelo outro.
@Suite struct TwinCardTests {
    private struct Enough: FreeSpaceProviding { func availableBytes(at url: URL) throws -> Int64 { .max } }
    let base = Date(timeIntervalSince1970: 1_780_000_000)

    func card(_ files: [(String, UInt8, TimeInterval)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("twin-" + UUID().uuidString)
        for (rel, seed, dt) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((0..<4096).map { UInt8((Int($0) * 31 + Int(seed)) & 0xFF) }).write(to: url)
            let d = base.addingTimeInterval(dt)
            try FileManager.default.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: url.path)
        }
        return root
    }
    func service() -> CopyService {
        CopyService(preset: .sampleConferencia, spaceProvider: Enough(), clock: { Date() }, activityKeeper: NoopActivityKeeper())
    }

    @Test func cartaoGemeoNaoPegaCarona() throws {
        // cartão A: DSC00001 (gêmeo) + 4 próprios; cartão B: DSC00001 com conteúdo diferente + 4 próprios
        let a = try card([("DCIM/100MSDCF/DSC00001.JPG", 1, 0)] + (2...5).map { ("DCIM/100MSDCF/DSC0000\($0).JPG", 1, Double($0) * 60) })
        let b = try card([("DCIM/100MSDCF/DSC00001.JPG", 9, 0)] + (6...9).map { ("DCIM/100MSDCF/DSC0000\($0).JPG", 9, Double($0) * 60) })
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("twin-dest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { for u in [a, b, dest] { try? FileManager.default.removeItem(at: u) } }

        _ = try service().run(cardRoot: a, chosenMedia: .both, destinations: [dest], camera: "A")

        // prévia de B: nada dele está salvo ainda
        let pv = try service().preview(cardRoot: b, chosenMedia: .both, destinations: [dest])
        #expect(pv.alreadyPresent == 0)
        // trava de formatar B antes de copiar: o gêmeo NÃO conta como salvo
        let wipe = try CardWipeCheck.evaluate(cardRoot: b, preset: .sampleConferencia,
                                              choices: WipeChoices(chosenMedia: .both, capturedIn: nil), destinations: [dest])
        #expect(wipe.notVerified.contains("DCIM/100MSDCF/DSC00001.JPG"))
        #expect(!wipe.canWipe)
        // a cópia de B grava os 5 de verdade (o gêmeo vai com outro nome), nenhum "já estava"
        let out = try service().run(cardRoot: b, chosenMedia: .both, destinations: [dest], camera: "B")
        #expect(out.verifiedCount == 5 && out.failures.isEmpty)
        let mB = try ManifestStore().loadAll(eventRootIn: dest, eventName: "Conferencia-Junho-2026")
            .first { $0.camera == "B" }
        #expect(mB?.files.allSatisfy { $0.status == "verified" } == true)
    }

    @Test func mesmoCartaoDeVoltaContinuaRapido() throws {
        // lote seguinte do MESMO cartão (não formatado + fotos novas): o que já foi salvo continua pulado
        let files = (1...5).map { ("DCIM/100MSDCF/DSC0000\($0).JPG", UInt8(1), Double($0) * 60) }
        let a = try card(files)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("twin-dest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { for u in [a, dest] { try? FileManager.default.removeItem(at: u) } }
        _ = try service().run(cardRoot: a, chosenMedia: .both, destinations: [dest], camera: "A")
        let extra = a.appendingPathComponent("DCIM/100MSDCF/DSC00006.JPG")
        try Data(repeating: 7, count: 4096).write(to: extra)
        let pv = try service().preview(cardRoot: a, chosenMedia: .both, destinations: [dest])
        #expect(pv.alreadyPresent == 5)
    }

    /// Cartões com arquivos de mesmo nome, tamanho e segundo (só o conteúdo muda): só a identidade do
    /// volume separa os dois. Nenhum registro pode sobrescrever o outro nem liberar a formatação do outro.
    @Test func gemeosIdenticosSeparadosPelaIdentidadeDoVolume() throws {
        let spec = (1...3).map { ("PRIVATE/M4ROOT/CLIP/C000\($0).MP4", UInt8(1), Double($0)) }
        let a = try card(spec)
        let b = try card(spec.map { ($0.0, UInt8(7), $0.2) })
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("twin-dest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { for u in [a, b, dest] { try? FileManager.default.removeItem(at: u) } }
        func svc(_ id: String) -> CopyService { var s = service(); s.cardIdentityOverride = id; return s }

        _ = try svc("AAAA").run(cardRoot: a, chosenMedia: .both, destinations: [dest], camera: "A")
        #expect(try svc("BBBB").preview(cardRoot: b, chosenMedia: .both, destinations: [dest]).alreadyPresent == 0)
        let wipe = try CardWipeCheck.evaluate(cardRoot: b, preset: .sampleConferencia,
                                              choices: WipeChoices(chosenMedia: .both, capturedIn: nil),
                                              destinations: [dest], cardIdentity: "BBBB")
        #expect(!wipe.canWipe)
        let out = try svc("BBBB").run(cardRoot: b, chosenMedia: .both, destinations: [dest], camera: "B")
        #expect(out.verifiedCount == 3)
        let all = try ManifestStore().loadAll(eventRootIn: dest, eventName: "Conferencia-Junho-2026")
        #expect(all.count == 2)                                    // nenhum registro sobrescreveu o outro
        #expect(Set(all.map { $0.source.volumeID }) == ["AAAA", "BBBB"])
        // e o próprio cartão A continua reconhecido como salvo
        #expect(try svc("AAAA").preview(cardRoot: a, chosenMedia: .both, destinations: [dest]).alreadyPresent == 3)
    }
}
