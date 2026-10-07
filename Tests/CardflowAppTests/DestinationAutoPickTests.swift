import Testing
import Foundation
@testable import CardflowApp
@testable import OffloadKit

@MainActor @Suite struct DestinationAutoPickTests {
    func tmpVolume(_ name: String, bytes: Int64, traits: DeviceTraits) -> ExternalVolume {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("autopick-\(UUID().uuidString)/\(name)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ExternalVolume(url: dir, name: name, isRemovable: true, isInternal: false, totalBytes: bytes,
                              physicalDeviceID: "disk-\(name)", traits: traits)
    }

    @Test func cartaoVazioNuncaEhDestinoMesmoSendoOMaior() {
        let sd = tmpVolume("Untitled", bytes: 128_000_000_000,
                           traits: DeviceTraits(protocolName: "Secure Digital", deviceModel: "SD Card Reader", mediaName: nil,
                                                isRemovableMedia: true, isInternalDevice: true, fileSystem: "exfat"))
        let ssd = tmpVolume("SSD", bytes: 12_000_000_000,
                            traits: DeviceTraits(protocolName: "USB", deviceModel: "Samsung PSSD T7", mediaName: nil,
                                                 isRemovableMedia: false, isInternalDevice: false, fileSystem: "apfs"))
        let m = AppModel(formatter: FakeFormatter())
        m.watcher.volumes = [sd, ssd]
        m.reconcileVolumes()
        #expect(m.destinations.allSatisfy { $0.url != sd.url })
        #expect(m.sources.contains { $0.url == sd.url })
        #expect(m.destinationURL == ssd.url)
    }

    @Test func cartaoForcadoComoDestinoNaoEhEscolhidoSozinho() {
        let sd = tmpVolume("Untitled", bytes: 128_000_000_000,
                           traits: DeviceTraits(protocolName: "Secure Digital", deviceModel: nil, mediaName: nil,
                                                isRemovableMedia: true, isInternalDevice: true, fileSystem: "exfat"))
        let m = AppModel(formatter: FakeFormatter())
        m.watcher.volumes = [sd]
        m.useAsDestination(sd)            // escolha explícita do usuário: entra na lista
        m.destinationURL = nil
        m.reconcileVolumes()
        #expect(m.destinations.contains { $0.url == sd.url })
        #expect(m.destinationURL != sd.url)   // mas o automático não pega cartão
    }
}
