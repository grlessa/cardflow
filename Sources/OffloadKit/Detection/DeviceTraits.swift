import Foundation

/// Tipo de mídia, pra ilustração e regra de destino. Vem do dispositivo físico, não do conteúdo.
public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case sd, cfexpressA, cfexpressB, cfast, ssd, hdd, recorder, genericCard, folder
}

/// O que o macOS diz do dispositivo físico (DiskArbitration). Classifica cartão de câmera PELO TIPO, não
/// só pelo conteúdo: um cartão recém-formatado está vazio e, antes, virava "disco comum" (e até destino
/// automático, por ser o maior disco montado).
public struct DeviceTraits: Equatable, Sendable {
    public var protocolName: String?   // DADeviceProtocol: "Secure Digital", "USB", "Thunderbolt", "PCI-Express", "Virtual Interface"
    public var deviceModel: String?    // DADeviceModel (nome do leitor ou do disco)
    public var mediaName: String?      // DAMediaName
    public var isRemovableMedia: Bool  // DAMediaRemovable (a MÍDIA sai do aparelho: cartão no leitor)
    public var isInternalDevice: Bool  // DADeviceInternal
    public var fileSystem: String?     // DAVolumeKind: "msdos", "exfat", "apfs", "hfs"

    public init(protocolName: String?, deviceModel: String?, mediaName: String?, isRemovableMedia: Bool,
                isInternalDevice: Bool, fileSystem: String?) {
        self.protocolName = protocolName; self.deviceModel = deviceModel; self.mediaName = mediaName
        self.isRemovableMedia = isRemovableMedia; self.isInternalDevice = isInternalDevice; self.fileSystem = fileSystem
    }

    private var names: String { [deviceModel, mediaName].compactMap { $0 }.joined(separator: " ").lowercased() }
    private var isDiskImage: Bool { protocolName == "Virtual Interface" }

    public var mediaKind: MediaKind {
        let n = names
        if protocolName == "Secure Digital" { return .sd }
        if n.contains("cfexpress") {
            return (n.contains("type a") || n.contains("type-a") || n.contains("tipo a")) ? .cfexpressA : .cfexpressB
        }
        if n.contains("xqd") { return .cfexpressB }
        if n.contains("cfast") { return .cfast }
        if n.contains(" sd ") || n.hasSuffix(" sd") || n.hasPrefix("sd ") || n.contains("sdxc") || n.contains("sdhc")
            || n.contains("sddr") || n.contains("sd reader") || n.contains("card reader") { return .sd }
        if isRemovableMedia && !isDiskImage && (fileSystem == "msdos" || fileSystem == "exfat") { return .genericCard }
        if n.contains("passport") || n.contains("hdd") || n.contains("expansion") || n.contains("elements")
            || n.contains("barracuda") || n.contains("rugged") { return .hdd }
        return .ssd
    }

    /// Cartão de câmera pelo tipo físico (mesmo vazio). Imagem de disco nunca conta pelo tipo.
    public var isCameraMedia: Bool {
        guard !isDiskImage else { return false }
        switch mediaKind {
        case .sd, .cfexpressA, .cfexpressB, .cfast, .genericCard: return true
        case .ssd, .hdd, .recorder, .folder: return false
        }
    }
}
