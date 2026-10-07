import Foundation
import OffloadKit

/// Uma pasta da prévia "Vai ficar assim": quantos arquivos do cartão caem nela, quanto pesam e alguns
/// nomes de exemplo reais (já renomeados pelo modelo).
struct TreeNode: Identifiable, Equatable, Sendable {
    var id: String          // caminho relativo ao destino
    var name: String
    var count: Int
    var bytes: Int64
    var samples: [String]
    var children: [TreeNode]?
}

enum OrganizationTree {
    /// Monta a árvore com o MESMO motor de nomes da cópia (NameBuilder), sobre os arquivos que a cópia
    /// levaria. Não reflete renomeação por colisão (nome repetido no destino), que só a cópia decide.
    static func build(files: [MediaFile], preset: Preset, camera: String, cameras: [String: String] = [:], cardName: String,
                      sessionValues: [String: String], lote: Int?, locale: Locale, samplesPerFolder: Int = 3) -> [TreeNode] {
        let nb = NameBuilder(preset: preset, locale: locale)
        final class Box { var count = 0; var bytes: Int64 = 0; var samples: [String] = []; var kids: [String: Box] = [:]; var order: [String] = [] }
        let root = Box()
        for (i, f) in files.enumerated() {
            let ctx = NamingContext(camera: cameras[CameraGroups.key(for: f)] ?? camera, counter: i + 1, cardName: cardName, sessionValues: sessionValues, lote: lote)
            guard let rel = try? nb.relativeDestination(for: f, context: ctx) else { continue }
            var parts = rel.split(separator: "/").map(String.init)
            guard let file = parts.popLast() else { continue }
            var node = root
            for p in parts {
                if node.kids[p] == nil { node.kids[p] = Box(); node.order.append(p) }
                node = node.kids[p]!
                node.count += 1; node.bytes += f.size
            }
            if node.samples.count < samplesPerFolder { node.samples.append(file) }
        }
        func convert(_ box: Box, path: String) -> [TreeNode] {
            box.order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
                let b = box.kids[name]!
                let id = path.isEmpty ? name : path + "/" + name
                let kids = convert(b, path: id)
                return TreeNode(id: id, name: name, count: b.count, bytes: b.bytes, samples: b.samples,
                                children: kids.isEmpty ? nil : kids)
            }
        }
        return convert(root, path: "")
    }
}
