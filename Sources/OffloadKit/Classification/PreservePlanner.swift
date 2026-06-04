import Foundation

/// Decide quais arquivos são copiados VERBATIM (preservando a árvore) vs achatados.
/// Puro: olha só a lista de `relPath`/`type` — sem I/O. Roda depois do scan, porque a
/// decisão "esse irmão pertence a um bundle de cinema?" precisa da lista inteira.
public enum PreservePlanner {
    /// Poluição do macOS — nunca preserva, mesmo dentro de um preserve root (senão é copiada verbatim).
    private static let systemJunk: Set<String> = [".ds_store", "thumbs.db", "desktop.ini"]

    /// Anota cada arquivo com `preserve`. Duas regras:
    /// (a) container de topo: 1º segmento que contenha ≥1 arquivo `.cinema` → tudo nele preserva;
    /// (b) grupo solto na raiz: arquivo `.cinema` solto + qualquer arquivo na raiz de mesmo nome-base.
    public static func plan(_ files: [MediaFile]) -> [MediaFile] {
        var preserveRoots = Set<String>()   // 1ºs segmentos de containers de cinema
        var looseStems = Set<String>()       // nomes-base de cinema solto na raiz
        for f in files where f.type == .cinema {
            let comps = f.relPath.split(separator: "/", omittingEmptySubsequences: true)
            if comps.count > 1 {
                preserveRoots.insert(String(comps[0]))
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
        if systemJunk.contains(name) { return false }   // poluição do macOS nunca preserva
        let comps = f.relPath.split(separator: "/", omittingEmptySubsequences: true)
        if comps.count > 1 { return roots.contains(String(comps[0])) }
        // solto na raiz: o próprio cinema preserva; um companheiro de mesmo nome-base só é absorvido se
        // NÃO for mídia plana (foto/vídeo/áudio) — senão uma foto de nome coincidente (A001.braw + A001.jpg)
        // viraria preserve e, num offload só-foto, seria DROPADA. Sidecar/metadata gruda normalmente.
        if f.type == .cinema { return true }
        guard stems.contains((f.relPath as NSString).deletingPathExtension) else { return false }
        return f.type != .photo && f.type != .video && f.type != .audio
    }

    /// Chave do pacote a que um arquivo pertence: 1º segmento (container: A001.RDM/CONTENTS/XDROOT)
    /// ou nome-base (grupo solto: "clip" de clip.braw/clip.sidecar).
    public static func bundleKey(_ relPath: String) -> String {
        let comps = relPath.split(separator: "/", omittingEmptySubsequences: true)
        return comps.count > 1 ? String(comps[0]) : (relPath as NSString).deletingPathExtension
    }

    /// Conta PACOTES distintos preservados (não arquivos): um clipe RED são muitos `.R3D`,
    /// mas é 1 pacote pro usuário.
    public static func bundleCount(_ files: [MediaFile]) -> Int {
        var keys = Set<String>()
        for f in files where f.preserve { keys.insert(bundleKey(f.relPath)) }
        return keys.count
    }
}
