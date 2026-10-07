import Testing
import Foundation
@testable import OffloadKit

@Suite struct DeviceTraitsTests {
    func t(_ proto: String?, model: String? = nil, media: String? = nil, removable: Bool = true,
           internalDev: Bool = false, fs: String? = "exfat") -> DeviceTraits {
        DeviceTraits(protocolName: proto, deviceModel: model, mediaName: media, isRemovableMedia: removable,
                     isInternalDevice: internalDev, fileSystem: fs)
    }

    @Test func sdDoLeitorDoMacEhCartaoMesmoVazio() {
        let sd = t("Secure Digital", model: "SD Card Reader", internalDev: true)
        #expect(sd.isCameraMedia && sd.mediaKind == .sd)
    }
    @Test func leitoresUSBPeloNome() {
        #expect(t("USB", model: "CFexpress Type B Card Reader").mediaKind == .cfexpressB)
        #expect(t("USB", model: "ProGrade Digital CFexpress Type A").mediaKind == .cfexpressA)
        #expect(t("USB", model: "Lexar CFast 2.0 Reader").mediaKind == .cfast)
        #expect(t("USB", model: "SanDisk SDDR-B531 SD Reader").mediaKind == .sd)
        #expect(t("USB", model: "CFexpress Type B Card Reader").isCameraMedia)
    }
    @Test func ssdEHDExternosNaoSaoCartao() {
        let ssd = t("USB", model: "Samsung PSSD T7", removable: false, fs: "apfs")
        #expect(!ssd.isCameraMedia && ssd.mediaKind == .ssd)
        let ssd2 = t("USB", model: "SanDisk Extreme Portable SSD", removable: false, fs: "exfat")
        #expect(!ssd2.isCameraMedia && ssd2.mediaKind == .ssd)
        let hd = t("USB", model: "WD My Passport 2626", media: "WD My Passport 2626 Media", removable: false, fs: "hfs")
        #expect(!hd.isCameraMedia && hd.mediaKind == .hdd)
    }
    @Test func removivelGenericoFATEhCartao() {
        let x = t("USB", model: "Generic Mass Storage", removable: true, fs: "msdos")
        #expect(x.isCameraMedia && x.mediaKind == .genericCard)
    }
    @Test func imagemDeDiscoNaoEhCartaoPorTipo() {
        #expect(!t("Virtual Interface", model: "Disk Image", removable: true).isCameraMedia)
    }
    @Test func cartaoVazioPeloTipoEhFonte() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var v = ExternalVolume(url: dir, name: "Untitled", isRemovable: true, isInternal: true)
        #expect(!CardDetection.isCard(v))                       // vazio e sem tipo: não dá pra saber
        v.traits = t("Secure Digital", internalDev: true)
        #expect(CardDetection.isCard(v) && v.mediaKind == .sd)  // vazio, mas é SD
    }
}
