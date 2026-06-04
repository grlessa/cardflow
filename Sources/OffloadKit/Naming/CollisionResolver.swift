import Foundation

public struct CollisionResolver {
    public enum Resolution: Equatable {
        case use(String)             // caminho livre para gravar
        case alreadyPresent(String)  // conteúdo idêntico já existe → pular
    }

    public init() {}

    /// `existingHash`: dado um caminho relativo candidato, devolve o hash do conteúdo já
    /// presente no destino (ciente do filesystem) ou `nil` se o caminho está livre.
    /// `suffixes`: sufixos determinísticos a tentar, em ordem (ex: ["_2026-05-28_110640", "_a1b2c3d4"]).
    public func resolve(desired: String, sourceHash: UInt64,
                        existingHash: (String) -> UInt64?, suffixes: [String]) -> Resolution {
        if let h = existingHash(desired) {
            if h == sourceHash { return .alreadyPresent(desired) }
        } else {
            return .use(desired)
        }
        for suffix in suffixes {
            let candidate = Self.insert(suffix: suffix, into: desired)
            if let h = existingHash(candidate) {
                if h == sourceHash { return .alreadyPresent(candidate) }
            } else {
                return .use(candidate)
            }
        }
        let hashSuffix = "_" + String(sourceHash, radix: 16)
        return .use(Self.insert(suffix: hashSuffix, into: desired))
    }

    /// Insere o sufixo antes da extensão: "a/b/DSC1.jpg" + "_x" → "a/b/DSC1_x.jpg".
    static func insert(suffix: String, into path: String) -> String {
        let ns = path as NSString
        let ext = ns.pathExtension
        let withoutExt = ns.deletingPathExtension
        return ext.isEmpty ? "\(withoutExt)\(suffix)" : "\(withoutExt)\(suffix).\(ext)"
    }
}
