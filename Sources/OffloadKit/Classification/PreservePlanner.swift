import Foundation

/// Decide quais arquivos são copiados VERBATIM (preservando a árvore) vs achatados.
/// Puro: olha só a lista de `relPath`/`type` — sem I/O. Roda depois do scan, porque a
/// decisão "esse irmão pertence a um bundle de cinema?" precisa da lista inteira.
public enum PreservePlanner {
    /// Poluição do macOS — nunca preserva, mesmo dentro de um preserve root (senão é copiada verbatim).
    private static let systemJunk: Set<String> = [".ds_store", "thumbs.db", "desktop.ini"]

    private static let multiUseTopDirs: Set<String> = ["DCIM", "PRIVATE"]

    private static func containerKey(for comps: [Substring]) -> String {
        if comps.count >= 3 && multiUseTopDirs.contains(comps[0].uppercased()) {
            return "\(comps[0])/\(comps[1])"
        }
        return String(comps[0])
    }

    /// Anota cada arquivo com `preserve`. Duas regras:
    /// (a) container de topo: 1º segmento (ou 2º sob DCIM/PRIVATE, ex.: PRIVATE/XDROOT) que contenha
    ///     >= 1 arquivo `.cinema` -> tudo nele preserva sem engolir fotos planas em pastas irmãs;
    /// (b) grupo solto na raiz: arquivo `.cinema` solto + qualquer arquivo na raiz de mesmo nome-base.
    public static func plan(_ files: [MediaFile]) -> [MediaFile] {
        var preserveRoots = Set<String>()
        var looseStems = Set<String>()
        for f in files where f.type == .cinema {
            let comps = f.relPath.split(separator: "/", omittingEmptySubsequences: true)
            if comps.count > 1 {
                preserveRoots.insert(containerKey(for: comps))
            } else {
                looseStems.insert((f.relPath as NSString).deletingPathExtension)
            }
        }
        return files.map { f in
            var f = f
            f.preserve = shouldPreserve(f, roots: preserveRoots, stems: looseStems)
            return f
        }
    }

    private static func shouldPreserve(_ f: MediaFile, roots: Set<String>, stems: Set<String>) -> Bool {
        let name = (f.relPath as NSString).lastPathComponent.lowercased()
        // Dotfiles (._* AppleDouble, .DS_Store) e lixo de sistema nunca preservam.
        if name.hasPrefix(".") || systemJunk.contains(name) { return false }
        let comps = f.relPath.split(separator: "/", omittingEmptySubsequences: true)
        if comps.count > 1 { return roots.contains(containerKey(for: comps)) }
        // solto na raiz: o próprio cinema preserva; um companheiro de mesmo nome-base só é absorvido se
        // NÃO for mídia plana (foto/vídeo/áudio) — senão uma foto de nome coincidente (A001.braw + A001.jpg)
        // viraria preserve e, num offload só-foto, seria DROPADA. Sidecar/metadata gruda normalmente.
        if f.type == .cinema { return true }
        guard stems.contains((f.relPath as NSString).deletingPathExtension) else { return false }
        return f.type != .photo && f.type != .video && f.type != .audio
    }

    /// Chave do pacote a que um arquivo pertence: container (A001.RDM/CONTENTS/PRIVATE/XDROOT)
    /// ou nome-base (grupo solto: "clip" de clip.braw/clip.sidecar).
    public static func bundleKey(_ relPath: String) -> String {
        let comps = relPath.split(separator: "/", omittingEmptySubsequences: true)
        return comps.count > 1 ? containerKey(for: comps) : (relPath as NSString).deletingPathExtension
    }

    /// Conta PACOTES distintos preservados (não arquivos): um clipe RED são muitos `.R3D`,
    /// mas é 1 pacote pro usuário.
    public static func bundleCount(_ files: [MediaFile]) -> Int {
        var keys = Set<String>()
        for f in files where f.preserve { keys.insert(bundleKey(f.relPath)) }
        return keys.count
    }
}
