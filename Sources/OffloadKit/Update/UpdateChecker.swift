import Foundation

/// Uma versão mais nova disponível no GitHub.
public struct UpdateInfo: Equatable, Sendable {
    public let version: String   // sem o "v", ex.: "0.2.0"
    public let pageURL: URL      // página de download (html_url da release)
}

/// Checagem de atualização discreta: pergunta ao GitHub se há uma release mais nova.
/// É a ÚNICA parte do app que toca a internet. Não envia NADA — só faz um GET público
/// e lê o número da versão. Qualquer falha (sem rede, repo privado, 404) vira `nil`
/// silenciosamente, então o uso offline nunca é atrapalhado.
public enum UpdateChecker {
    public static let owner = "grlessa"
    public static let repo = "cardflow"

    /// Compara versões "x.y.z" numericamente (tolera prefixo "v" e sufixos tipo "-beta").
    /// true quando `remote` é estritamente mais nova que `local`.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let core = s.drop(while: { !$0.isNumber })                  // descarta um "v" inicial
            return core.split(whereSeparator: { !$0.isNumber }).prefix(3).map { Int($0) ?? 0 }
        }
        let r = parts(remote), l = parts(local)
        for i in 0..<3 {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    private struct Release: Decodable { let tag_name: String; let html_url: String }

    /// Consulta a última release. Devolve `UpdateInfo` só quando há versão MAIS NOVA que `current`.
    public static func checkForUpdate(current: String,
                                      session: URLSession = .shared) async -> UpdateInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              let page = URL(string: release.html_url),
              isNewer(release.tag_name, than: current)
        else { return nil }
        return UpdateInfo(version: String(release.tag_name.drop(while: { !$0.isNumber })), pageURL: page)
    }
}
