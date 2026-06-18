import Foundation

public struct ExternalVolume: Equatable, Identifiable, Sendable {
    public var url: URL
    public var name: String
    public var isRemovable: Bool
    public var isInternal: Bool
    public var totalBytes: Int64?        // capacidade do volume (pra ordenar destinos por tamanho)
    public var physicalDeviceID: String? // disco físico (whole-disk BSD, ex.: "disk4") — backup ≠ mesmo disco
    public var volumeUUID: String?       // identidade estável do volume (lembrar destino entre sessões)
    public var isInternalShortcut: Bool  // atalho de pasta no disco interno (Mesa/Documentos), não vem do watcher
    public var id: String { url.path }
    public init(url: URL, name: String, isRemovable: Bool, isInternal: Bool,
                totalBytes: Int64? = nil, physicalDeviceID: String? = nil, volumeUUID: String? = nil,
                isInternalShortcut: Bool = false) {
        self.url = url; self.name = name; self.isRemovable = isRemovable
        self.isInternal = isInternal; self.totalBytes = totalBytes
        self.physicalDeviceID = physicalDeviceID; self.volumeUUID = volumeUUID
        self.isInternalShortcut = isInternalShortcut
    }
}

public enum CardDetection {
    /// Pastas-marcador de câmera de nome exato na raiz — só as fortemente específicas, pra não dar
    /// falso-positivo em disco de trabalho. PRIVATE cobre Sony M4ROOT/XDROOT e Panasonic AVCHD;
    /// AVF_INFO (Sony/Panasonic), MP_ROOT (Sony MP4), CRM (Canon Cinema RAW Light). Cinema EOS XF /
    /// P2 (CONTENTS) é tratado à parte (exige pasta de clipe dentro).
    private static let cameraMarkers = ["DCIM", "PRIVATE", "AVF_INFO", "MP_ROOT", "CRM"]

    /// Extensões que, SOLTAS na raiz, indicam uma FONTE marker-less (gravador, Blackmagic, cinema,
    /// camcorder). Genéricas (jpg/mp4/mov/mp3) ficam de FORA: aparecem em disco de trabalho e dariam
    /// falso-positivo — cartão genérico de câmera tem DCIM (pego pelos marcadores).
    private static let looseSourceExtensions: Set<String> = [
        "wav", "m4a", "aac", "flac", "aiff", "aif",   // gravadores de áudio (mp3 fora: genérico demais)
        "braw", "r3d", "mxf", "mts", "m2ts",          // cinema / camcorder
    ]

    /// Clipes de cinema-original que indicam FONTE mesmo em subpasta (SSD organizado em pastas). Só os
    /// formatos de câmera (não áudio nem mov/mp4) pra não pegar disco de trabalho/backup.
    private static let recursiveCinemaExtensions: Set<String> = ["braw", "r3d", "mxf"]

    /// É fonte de mídia se for removível OU externo (SSD/HD que monta fixo) E tiver estrutura de fonte
    /// (pasta-marcador, CONTENTS-com-clipe, RED, extensão solta na raiz, ou clipe de cinema em subpasta).
    /// O leitor de SD embutido reporta interno mas removível → coberto pelo "removível". Disco de
    /// sistema (interno E não-removível) é barrado. Time Machine nunca é fonte.
    public static func isCard(_ vol: ExternalVolume) -> Bool {
        guard vol.isRemovable || !vol.isInternal else { return false }
        let fm = FileManager.default
        // Volume de rede (NAS): é destino/arquivo, não fonte de offload — e varrer pela rede é lento.
        if let vals = try? vol.url.resourceValues(forKeys: [.volumeIsLocalKey]), vals.volumeIsLocal == false {
            return false
        }
        let rootEntries = (try? fm.contentsOfDirectory(atPath: vol.url.path)) ?? []
        // Time Machine / imagens de backup nunca são fonte (não varrer footage de um backup). HFS+ TM
        // usa Backups.backupdb; APFS TM (Ventura+) e Carbon Copy Cloner usam .sparsebundle/.backupbundle.
        if rootEntries.contains(where: {
            $0 == "Backups.backupdb" || $0.hasSuffix(".sparsebundle") || $0.hasSuffix(".backupbundle")
        }) { return false }
        // 1) pasta-marcador de câmera de nome exato na raiz
        if cameraMarkers.contains(where: { fm.fileExists(atPath: vol.url.appendingPathComponent($0).path) }) {
            return true
        }
        // 2) Cinema EOS XF / Panasonic P2: CONTENTS com pasta de clipe (CLIP/CLIPS/CLIPS001…), não DCIM.
        let contents = vol.url.appendingPathComponent("CONTENTS")
        if let items = try? fm.contentsOfDirectory(atPath: contents.path),
           items.contains(where: { name in
               // exige PASTA de clipe (CLIP/CLIPS/CLIPS001…), não um ARQUIVO qualquer chamado CLIP* (ex.: CLIPBOARD.txt)
               guard name.uppercased().hasPrefix("CLIP") else { return false }
               var isDir: ObjCBool = false
               return fm.fileExists(atPath: contents.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
           }) {
            return true
        }
        // 3) marker-less: RED (pastas .RDM/.RDC) ou extensão de FONTE solta na raiz (gravador/cinema).
        for name in rootEntries {
            if name.hasPrefix(".") { continue }   // ignora lixo do macOS (.Spotlight-V100, .fseventsd, .Trashes)
            let upper = name.uppercased()
            if upper.hasSuffix(".RDM") || upper.hasSuffix(".RDC") { return true }
            if looseSourceExtensions.contains((name as NSString).pathExtension.lowercased()) { return true }
        }
        // 4) subpastas (até 2 níveis): clipe de cinema-original ou pasta RED — pega SSD organizado em
        //    pastas (SSD/Reel01/A001.braw). Teto de pastas + parada no 1º acerto limitam o I/O.
        return hasNestedCinemaSource(vol.url, fm: fm)
    }

    /// Procura clipe de cinema (.braw/.r3d/.mxf) ou pasta RED (.RDM/.RDC) até 2 níveis de subpasta.
    private static func hasNestedCinemaSource(_ root: URL, fm: FileManager) -> Bool {
        var budget = 400   // teto de pastas visitadas — não varre um disco de trabalho gigante
        func scan(_ dir: URL, _ depth: Int) -> Bool {
            guard depth >= 0, budget > 0, let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
            budget -= 1
            var subdirs: [URL] = []
            for name in items {
                if name.hasPrefix(".") || name == "Backups.backupdb" { continue }
                let url = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    let upper = name.uppercased()
                    if upper.hasSuffix(".RDM") || upper.hasSuffix(".RDC") { return true }
                    subdirs.append(url)
                } else if recursiveCinemaExtensions.contains((name as NSString).pathExtension.lowercased()) {
                    return true
                }
            }
            if depth == 0 { return false }
            for sub in subdirs where scan(sub, depth - 1) { return true }
            return false
        }
        return scan(root, 2)
    }
    public static func cards(from volumes: [ExternalVolume]) -> [ExternalVolume] {
        volumes.filter { isCard($0) }
    }
    public static func destinations(from volumes: [ExternalVolume]) -> [ExternalVolume] {
        volumes.filter { !isCard($0) }
    }
}
