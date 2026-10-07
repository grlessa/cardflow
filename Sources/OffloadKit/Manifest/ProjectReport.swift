import Foundation
import ImageIO

/// Relatório de entrega de um PROJETO: um HTML só, visível na pasta do projeto, juntando todas as cópias
/// (cartões) registradas nos manifestos. Na frente, o que qualquer pessoa precisa saber (posso formatar?);
/// dentro de "Detalhes técnicos", a prova completa (hash de cada arquivo, tempos, impressão do cartão).
/// Função pura: recebe os manifestos e devolve o texto. Quem grava é o `ManifestStore`.
public enum ProjectReport {
    public static let allFileNames = ["Relatório Cardflow.html", "Cardflow Report.html", "Informe Cardflow.html"]

    public static func fileName(locale: Locale) -> String {
        switch ReportLang(locale).code {
        case "en": return allFileNames[1]
        case "es": return allFileNames[2]
        default: return allFileNames[0]
        }
    }

    /// Âncora da seção de um cartão (o app abre o relatório já nela).
    public static func anchor(for m: Manifest) -> String { "cartao-" + CardFingerprint.shortID(m.offloadId) }

    public static func html(manifests: [Manifest], projectName: String, locale: Locale) -> String {
        let L = ReportLang(locale)
        // retomada reescreve o mesmo offloadId: fica o registro mais recente de cada cópia.
        let runs = Dictionary(grouping: manifests, by: \.offloadId).values
            .compactMap { $0.max { $0.finishedAt < $1.finishedAt } }
            .sorted { $0.finishedAt < $1.finishedAt }
        let ctx = Context(L: L, locale: locale, runs: runs, projectName: projectName)
        return [ctx.head(), ctx.top(), ctx.hero(), ctx.whereSaved(), ctx.cards(), ctx.folders(), ctx.technical(),
                ctx.foot()].joined(separator: "\n")
    }
}

/// Textos do relatório por idioma. Tabela fixa (determinística), porque entra em arquivo gravado.
struct ReportLang {
    let code: String
    init(_ locale: Locale) {
        let c = locale.language.languageCode?.identifier ?? "pt"
        code = ["en", "es"].contains(c) ? c : "pt"
    }
    func s(_ pt: String, _ en: String, _ es: String) -> String { code == "en" ? en : (code == "es" ? es : pt) }
    /// "1 cartão" / "4 cartões".
    func n(_ count: Int, _ one: (String, String, String), _ many: (String, String, String)) -> String {
        "\(count) " + (count == 1 ? s(one.0, one.1, one.2) : s(many.0, many.1, many.2))
    }
    /// "A001, B002 e C003".
    func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + s(" e ", " and ", " y ") + items.last!
    }
    func bytes(_ b: Int64) -> String {
        let raw = Format.humanBytes(b)
        return code == "en" ? raw : raw.replacingOccurrences(of: ".", with: ",")
    }
    func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return sec == 0 || m >= 10 ? "\(m) min" : "\(m) min \(sec) s" }
        return "\(sec) s"
    }
}

private struct Context {
    let L: ReportLang
    let locale: Locale
    let runs: [Manifest]
    let projectName: String

    // MARK: dados derivados

    /// Arquivos de mídia (fora de .cardflow), sem repetir o mesmo destino entre cópias.
    var mediaFiles: [Manifest.FileRecord] {
        var seen = Set<String>(); var out: [Manifest.FileRecord] = []
        for r in runs { for f in r.files where !isAside(f) && seen.insert(f.destRelPath).inserted { out.append(f) } }
        return out
    }
    var destinations: [String] {
        var seen = Set<String>(); var out: [String] = []
        for r in runs { for d in r.destinations where seen.insert(d).inserted { out.append(d) } }
        return out
    }
    func isAside(_ f: Manifest.FileRecord) -> Bool { f.destRelPath.contains("/.cardflow/") }
    func failedCount(_ r: Manifest) -> Int { max(r.totals.failed, r.failedPaths?.count ?? 0) }
    var failedRuns: [Manifest] { runs.filter { failedCount($0) > 0 } }
    var interruptedRuns: [Manifest] { runs.filter { $0.interrupted && failedCount($0) == 0 } }
    /// Cópias que deixaram câmeras no cartão de propósito (material de outra pessoa).
    var keptRuns: [Manifest] { runs.filter { !($0.keptCameras ?? []).isEmpty && failedCount($0) == 0 && !$0.interrupted } }

    func date(_ d: Date, time: Bool = true) -> String {
        let f = DateFormatter(); f.locale = locale; f.dateStyle = .medium; f.timeStyle = time ? .short : .none
        return f.string(from: d)
    }
    func shortDate(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = locale; f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: d)
    }
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Ícone do dispositivo de cada cópia: o do macOS (o mesmo da barra lateral do app), embutido uma vez
    /// por tipo no CSS. Sem o arquivo do sistema, um desenho que segue o do macOS.
    func iconKey(_ r: Manifest) -> String { DeviceIcon.key(for: r.source.mediaKind) }
    func deviceIcon(_ r: Manifest) -> String {
        let key = iconKey(r)
        if key == "folder" { return "<span class=\"dev\">\(Self.folderGlyph)</span>" }
        return DeviceIcon.dataURI(key) == nil ? Self.sdGlyph : "<span class=\"dev dev-\(key)\" role=\"img\"></span>"
    }
    var iconCSS: String {
        let disks = destinations.map { $0.hasPrefix("/Volumes/") ? "external" : "internal" }
        return Set(runs.map(iconKey) + disks).sorted().compactMap { k in
            DeviceIcon.dataURI(k).map { "\n.dev-\(k){background-image:url(\($0))}" }
        }.joined()
    }

    // MARK: blocos

    func head() -> String {
        """
        <!DOCTYPE html>
        <html lang="\(L.code == "pt" ? "pt-BR" : L.code)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta name="generator" content="Cardflow">
        <title>\(esc(projectName)) · \(esc(L.s("Relatório Cardflow", "Cardflow Report", "Informe Cardflow")))</title>
        <style>\(Self.css)\(iconCSS)</style>
        </head>
        <body>
        <main>
        """
    }

    func top() -> String {
        let last = runs.last.map { L.s("Última cópia em ", "Last copy on ", "Última copia el ") + date($0.finishedAt) } ?? ""
        return """
        <header class="top">
          <div class="bar">
            <div class="brand">\(Self.logo)<span>Cardflow</span><span class="kind">\(esc(L.s("Relatório do projeto", "Project report", "Informe del proyecto")))</span></div>
            <button class="print" type="button" onclick="window.print()">\(esc(L.s("Imprimir ou salvar PDF", "Print or save PDF", "Imprimir o guardar PDF")))</button>
          </div>
          <h1>\(esc(projectName))</h1>
          <p class="muted">\(esc(last))</p>
        </header>
        """
    }

    func hero() -> String {
        let cls: String, icon: String, title: String, body: String
        if !failedRuns.isEmpty {
            let n = failedRuns.reduce(0) { $0 + failedCount($1) }
            cls = "fail"; icon = Self.iconFail
            title = L.s("Não formate ", "Do not format ", "No formatees ") + L.list(failedRuns.map(\.source.volumeName)) + "."
            body = (n == 1 ? L.s("1 arquivo não passou na conferência.", "1 file failed verification.", "1 archivo no pasó la verificación.")
                           : L.s("\(n) arquivos não passaram na conferência.", "\(n) files failed verification.", "\(n) archivos no pasaron la verificación."))
                + " " + L.s("Copie de novo antes de apagar o cartão.", "Copy again before erasing the card.", "Copia de nuevo antes de borrar la tarjeta.")
        } else if !interruptedRuns.isEmpty {
            cls = "warn"; icon = Self.iconWarn
            title = L.s("Cópia interrompida.", "Copy interrupted.", "Copia interrumpida.")
            body = L.s("O registro de ", "The record for ", "El registro de ") + L.list(interruptedRuns.map(\.source.volumeName))
                + L.s(" é parcial. Mantenha o cartão como está e copie de novo.",
                      " is partial. Keep the card as it is and copy again.",
                      " es parcial. Deja la tarjeta como está y copia de nuevo.")
        } else if !keptRuns.isEmpty {
            cls = "warn"; icon = Self.iconWarn
            title = L.s("Copiado, mas não formate ", "Copied, but do not format ", "Copiado, pero no formatees ")
                + L.list(keptRuns.map(\.source.volumeName)) + "."
            let cams = L.list(Array(Set(keptRuns.flatMap { $0.keptCameras ?? [] })).sorted())
            body = L.s("Ficaram no cartão os arquivos de \(cams), que não foram copiados.",
                       "The files from \(cams) were left on the card and not copied.",
                       "Los archivos de \(cams) quedaron en la tarjeta y no se copiaron.")
        } else if runs.isEmpty {
            cls = "warn"; icon = Self.iconWarn
            title = L.s("Nenhuma cópia registrada.", "No copies recorded.", "Ninguna copia registrada.")
            body = ""
        } else {
            cls = "ok"; icon = Self.iconOk
            title = L.s("Tudo conferido.", "All verified.", "Todo verificado.")
            let c = runs.count
            let dests = L.n(destinations.count, ("destino", "destination", "destino"), ("destinos", "destinations", "destinos"))
            let allFormatted = runs.allSatisfy { $0.cardFormatted != nil }
            if c == 1 {
                body = L.s("O cartão está salvo em \(dests) e ", "The card is saved to \(dests) and ", "La tarjeta está guardada en \(dests) y ")
                    + (allFormatted ? L.s("já foi formatado.", "has been formatted.", "ya se formateó.")
                                    : L.s("pode ser formatado.", "can be formatted.", "se puede formatear."))
            } else {
                body = L.s("Os \(c) cartões estão salvos em \(dests) e ", "All \(c) cards are saved to \(dests) and ",
                           "Las \(c) tarjetas están guardadas en \(dests) y ")
                    + (allFormatted ? L.s("já foram formatados.", "have been formatted.", "ya se formatearon.")
                                    : L.s("podem ser formatados.", "can be formatted.", "se pueden formatear."))
            }
        }
        return """
        <section class="hero \(cls)">
          <div class="verdict">
            <div class="vicon">\(icon)</div>
            <div><h2>\(esc(title))</h2>\(body.isEmpty ? "" : "<p>\(esc(body))</p>")</div>
          </div>
          \(runs.isEmpty ? "" : figures())
        </section>
        """
    }

    func figures() -> String {
        let files = mediaFiles
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        func fig(_ value: String, _ label: String) -> String {
            "<div class=\"fig\"><dd>\(esc(value))</dd><dt>\(esc(label))</dt></div>"
        }
        return """
        <dl class="figures">
          \(fig("\(files.count)", files.count == 1 ? L.s("arquivo conferido", "file verified", "archivo verificado") : L.s("arquivos conferidos", "files verified", "archivos verificados")))
          \(fig(L.bytes(total), L.s("no total", "in total", "en total")))
          \(fig("\(runs.count)", runs.count == 1 ? L.s("cartão", "card", "tarjeta") : L.s("cartões", "cards", "tarjetas")))
          \(fig("\(destinations.count)", destinations.count == 1 ? L.s("destino", "destination", "destino") : L.s("destinos", "destinations", "destinos")))
        </dl>
        """
    }

    /// Onde a pasta do projeto ficou: disco e caminho, em cada destino.
    func whereSaved() -> String {
        guard !destinations.isEmpty else { return "" }
        let folder = mediaFiles.first.flatMap { $0.destRelPath.split(separator: "/").first.map(String.init) } ?? projectName
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let rows = destinations.map { d -> String in
            let parts = d.split(separator: "/").map(String.init)
            let disk = d.hasPrefix("/Volumes/") && parts.count > 1 ? parts[1] : L.s("Este Mac", "This Mac", "Este Mac")
            var path = (d as NSString).appendingPathComponent(folder)
            if path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
            let icon = d.hasPrefix("/Volumes/") ? "external" : "internal"
            let glyph = DeviceIcon.dataURI(icon) == nil ? Self.driveGlyph : "<span class=\"dev dev-\(icon)\" role=\"img\"></span>"
            return "<li>\(glyph)<div><strong>\(esc(disk))</strong><code>\(esc(path))</code></div></li>"
        }.joined()
        return "<h2 class=\"sec\">\(esc(L.s("Onde estão os arquivos", "Where the files are", "Dónde están los archivos")))</h2>\n<ul class=\"where\">\(rows)</ul>"
    }

    func cards() -> String {
        guard !runs.isEmpty else { return "" }
        let items = runs.map(card).joined(separator: "\n")
        return "<h2 class=\"sec\">\(esc(L.s("Cartões", "Cards", "Tarjetas")))</h2>\n<div class=\"cards\">\n\(items)\n</div>"
    }

    func card(_ r: Manifest) -> String {
        let failed = failedCount(r)
        let pill: (String, String)
        if failed > 0 { pill = ("fail", L.s("Falhou", "Failed", "Falló")) }
        else if r.interrupted { pill = ("warn", L.s("Interrompido", "Interrupted", "Interrumpido")) }
        else if !(r.keptCameras ?? []).isEmpty { pill = ("warn", L.s("Não formatar", "Do not format", "No formatear")) }
        else if r.cardFormatted != nil { pill = ("ok", L.s("Conferido e formatado", "Verified and formatted", "Verificada y formateada")) }
        else { pill = ("ok", L.s("Conferido", "Verified", "Verificado")) }

        var counts: [String] = []
        let t = r.totals
        func kind(_ n: Int, _ one: (String, String, String), _ many: (String, String, String)) {
            guard n > 0 else { return }
            let word = n == 1 ? L.s(one.0, one.1, one.2) : L.s(many.0, many.1, many.2)
            counts.append("<span class=\"k\"><strong>\(n)</strong> \(esc(word))</span>")
        }
        kind(t.photos, ("foto", "photo", "foto"), ("fotos", "photos", "fotos"))
        kind(t.videos, ("vídeo", "video", "vídeo"), ("vídeos", "videos", "vídeos"))
        kind(t.audio, ("áudio", "audio file", "audio"), ("áudios", "audio files", "audios"))
        kind(t.cinema, ("clipe de cinema", "cinema clip", "clip de cine"), ("clipes de cinema", "cinema clips", "clips de cine"))
        let bytes = r.files.filter { !isAside($0) }.reduce(Int64(0)) { $0 + $1.bytes }
        counts.append("<span class=\"k size\">\(esc(L.bytes(bytes)))</span>")

        var notes: [String] = []
        let present = r.files.filter { $0.status == "present" && !isAside($0) }.count
        if present > 0 {
            notes.append(present == 1 ? L.s("1 já estava no destino", "1 was already at the destination", "1 ya estaba en el destino")
                                      : L.s("\(present) já estavam no destino", "\(present) were already at the destination", "\(present) ya estaban en el destino"))
        }
        if let ex = r.excludedByChoice, !ex.isEmpty {
            // auxiliares (XML, THM…) à parte: "12 ficaram no cartão" sozinho parecia mídia faltando
            let classifier = FileClassifier()
            let aux = ex.filter { classifier.classify(fileName: ($0 as NSString).lastPathComponent) == .sidecar }.count
            let media = ex.count - aux
            if media > 0 {
                notes.append(media == 1 ? L.s("1 ficou no cartão por escolha", "1 left on the card by choice", "1 se quedó en la tarjeta por elección")
                                        : L.s("\(media) ficaram no cartão por escolha", "\(media) left on the card by choice", "\(media) se quedaron en la tarjeta por elección"))
            }
            if aux > 0 {
                notes.append(aux == 1 ? L.s("1 arquivo auxiliar (XML, THM…) ficou no cartão", "1 auxiliary file (XML, THM…) left on the card", "1 archivo auxiliar (XML, THM…) quedó en la tarjeta")
                                      : L.s("\(aux) arquivos auxiliares (XML, THM…) ficaram no cartão", "\(aux) auxiliary files (XML, THM…) left on the card", "\(aux) archivos auxiliares (XML, THM…) quedaron en la tarjeta"))
            }
        }
        if let kept = r.keptCameras, !kept.isEmpty {
            notes.append(L.s("Ficaram no cartão: ", "Left on the card: ", "Quedaron en la tarjeta: ") + L.list(kept))
        }
        if r.interrupted {
            notes.append(L.s("Registro parcial: a cópia parou antes do fim", "Partial record: the copy stopped before the end", "Registro parcial: la copia se detuvo antes del final"))
        }
        if let f = r.cardFormatted {
            notes.append(L.s("Formatado em ", "Formatted on ", "Formateada el ") + date(f.at)
                         + " (\(f.fileSystem), " + L.s("blocos de ", "", "bloques de ") + "\(f.clusterBytes / 1024) KB" + L.s("", " clusters", "") + ")")
        }

        var failures = ""
        if let paths = r.failedPaths, !paths.isEmpty {
            failures = "<div class=\"failures\"><strong>\(esc(L.s("Não passaram na conferência", "Failed verification", "No pasaron la verificación")))</strong><ul>"
                + paths.prefix(50).map { "<li><code>\(esc($0))</code></li>" }.joined()
                + (paths.count > 50 ? "<li>\(esc(more(paths.count - 50)))</li>" : "") + "</ul></div>"
        }

        let camera = CameraMetadata.isMeaningful(r.camera) ? " · " + L.s("Câmera ", "Camera ", "Cámara ") + r.camera : ""
        let secs = r.finishedAt.timeIntervalSince(r.startedAt)   // retomada sem nada novo leva 0 s: não mostra
        let when = date(r.finishedAt) + (secs >= 1 ? " · " + L.s("levou ", "took ", "tardó ") + L.duration(secs) : "")
        return """
        <section class="card" id="\(ProjectReport.anchor(for: r))">
          <div class="chead">
            \(deviceIcon(r))
            <div class="cname"><h3>\(esc(r.source.volumeName))</h3><div class="muted small">\(esc(when + camera))</div></div>
            <span class="pill \(pill.0)">\(esc(pill.1))</span>
          </div>
          <div class="counts">\(counts.joined())</div>
          \(notes.isEmpty ? "" : "<ul class=\"notes\">" + notes.map { "<li>\(esc($0))</li>" }.joined() + "</ul>")
          \(failures)
        </section>
        """
    }

    func more(_ n: Int) -> String { L.s("e mais \(n)", "and \(n) more", "y \(n) más") }

    /// Árvore das pastas criadas (a partir dos destRelPath), com contagem e tamanho por pasta.
    func folders() -> String {
        final class Node { var children: [String: Node] = [:]; var count = 0; var bytes: Int64 = 0 }
        let root = Node()
        for f in mediaFiles {
            var parts = f.destRelPath.split(separator: "/").map(String.init)
            guard parts.count > 1 else { continue }
            parts.removeLast()
            var n = root
            for p in parts {
                let c = n.children[p] ?? Node(); n.children[p] = c; n = c
                n.count += 1; n.bytes += f.bytes
            }
        }
        guard !root.children.isEmpty else { return "" }
        func render(_ node: Node, depth: Int) -> String {
            let keys = node.children.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            var out = "<ul>"
            for k in keys.prefix(40) {
                let c = node.children[k]!
                let meta = L.n(c.count, ("arquivo", "file", "archivo"), ("arquivos", "files", "archivos")) + " · " + L.bytes(c.bytes)
                out += "<li><div class=\"row\"><span class=\"folder\">\(Self.folderGlyph)<span>\(esc(k))</span></span><span class=\"meta\">\(esc(meta))</span></div>"
                if !c.children.isEmpty { out += render(c, depth: depth + 1) }
                out += "</li>"
            }
            if keys.count > 40 { out += "<li class=\"muted\">\(esc(more(keys.count - 40)))</li>" }
            return out + "</ul>"
        }
        return "<h2 class=\"sec\">\(esc(L.s("Pastas criadas", "Folders created", "Carpetas creadas")))</h2>\n<div class=\"tree\">\(render(root, depth: 0))</div>"
    }

    func technical() -> String {
        guard !runs.isEmpty else { return "" }
        let method = L.s("Cada arquivo foi copiado e depois relido no destino. O xxHash64 da cópia é igual ao do cartão, o que prova que os dois são idênticos byte a byte.",
                         "Each file was copied and then read back from the destination. The copy's xxHash64 matches the card's, which proves both are identical byte for byte.",
                         "Cada archivo se copió y luego se volvió a leer en el destino. El xxHash64 de la copia coincide con el de la tarjeta, lo que prueba que ambos son idénticos byte a byte.")

        let runRows = runs.map { r -> String in
            let real = r.finishedAt.timeIntervalSince(r.startedAt)
            let secs = max(1, real)
            let copied = r.files.filter { $0.status == "verified" }.reduce(Int64(0)) { $0 + $1.bytes }
            let speed = copied > 0 ? L.bytes(Int64(Double(copied) / secs)) + "/s" : "—"
            let json = ManifestStore.jsonFileName(for: r)
            return "<tr><td>\(esc(r.source.volumeName))</td><td class=\"num\">\(esc(shortDate(r.startedAt)))</td><td class=\"num\">\(esc(real < 1 ? "< 1 s" : L.duration(secs)))</td>"
                + "<td class=\"num\">\(esc(speed))</td><td><code>\(esc(String(r.source.fingerprint.prefix(12))))</code></td>"
                + "<td>\(esc(r.presetName))</td>"
                + "<td><a href=\".cardflow/\(esc(json))\">JSON</a></td></tr>"
        }.joined(separator: "\n")

        let dests = destinations.map { "<li><code>\(esc($0))</code></li>" }.joined()

        let fileRows = runs.map { r -> String in
            let header = "<tr class=\"group\"><th colspan=\"5\">\(esc(r.source.volumeName))</th></tr>"
            return header + r.files.map { f -> String in
                let status = f.status == "present" ? L.s("já estava", "already there", "ya estaba") : L.s("conferido", "verified", "verificado")
                let when = f.sourceDate.map { shortDate($0) } ?? "—"
                let q = (f.sourceRelPath + " " + f.destRelPath + " " + r.source.volumeName + " " + f.xxhash64).lowercased()
                // caminho relativo à pasta do projeto (o nome do projeto já está no título)
                let prefix = projectName + "/"
                let shown = f.destRelPath.hasPrefix(prefix) ? String(f.destRelPath.dropFirst(prefix.count)) : f.destRelPath
                return "<tr data-q=\"\(esc(q))\"><td class=\"path\"><code>\(esc(shown))</code>"
                    + "<div class=\"src\">\(esc(L.s("no cartão: ", "on card: ", "en la tarjeta: ")))<code>\(esc(f.sourceRelPath))</code></div></td>"
                    + "<td class=\"num\">\(esc(L.bytes(f.bytes)))</td><td class=\"num\">\(esc(when))</td>"
                    + "<td><code class=\"hash\">\(esc(f.xxhash64))</code></td><td class=\"nowrap\">\(esc(status))</td></tr>"
            }.joined(separator: "\n")
        }.joined(separator: "\n")
        let fileCount = runs.reduce(0) { $0 + $1.files.count }

        let aside = runs.flatMap(\.files).filter(isAside)
        let sidecars = aside.filter { $0.destRelPath.contains("/.cardflow/sidecars/") }
        let unknown = runs.flatMap(\.unrecognized)
        var extras = ""
        if !unknown.isEmpty {
            extras += "<h4>\(esc(L.s("Itens não reconhecidos", "Unrecognized items", "Elementos no reconocidos")))</h4><p class=\"muted\">"
                + esc(L.s("O Cardflow não reconhece estes arquivos como mídia. Mesmo assim, eles foram copiados e conferidos em .cardflow/desconhecidos, dentro da pasta do projeto.",
                          "Cardflow does not recognize these files as media. They were still copied and verified to .cardflow/desconhecidos, inside the project folder.",
                          "Cardflow no reconoce estos archivos como medios. Aun así, se copiaron y verificaron en .cardflow/desconhecidos, dentro de la carpeta del proyecto."))
                + "</p><ul class=\"paths\">" + unknown.prefix(200).map { "<li><code>\(esc($0))</code></li>" }.joined()
                + (unknown.count > 200 ? "<li>\(esc(more(unknown.count - 200)))</li>" : "") + "</ul>"
        }
        if !sidecars.isEmpty {
            extras += "<h4>\(esc(L.s("Arquivos auxiliares", "Auxiliary files", "Archivos auxiliares")))</h4><p class=\"muted\">"
                + esc(L.s("Arquivos como XML e THM que acompanham a mídia. Foram copiados e conferidos em .cardflow/sidecars.",
                          "Files such as XML and THM that come with the media. They were copied and verified to .cardflow/sidecars.",
                          "Archivos como XML y THM que acompañan a los medios. Se copiaron y verificaron en .cardflow/sidecars."))
                + " " + esc(L.n(sidecars.count, ("arquivo", "file", "archivo"), ("arquivos", "files", "archivos"))) + ".</p>"
        }
        if !unknown.isEmpty || !sidecars.isEmpty {
            extras += "<p class=\"muted small\">" + esc(L.s("Para ver a pasta .cardflow no Finder, aperte ⇧⌘. (ponto).",
                                                           "To see the .cardflow folder in Finder, press ⇧⌘. (period).",
                                                           "Para ver la carpeta .cardflow en el Finder, pulsa ⇧⌘. (punto).")) + "</p>"
        }

        return """
        <details class="tech">
          <summary>\(esc(L.s("Detalhes técnicos", "Technical details", "Detalles técnicos")))<span class="hint">\(esc(L.s("hash de cada arquivo, tempos e registros", "per-file hashes, timings and records", "hash de cada archivo, tiempos y registros")))</span></summary>
          <div class="techbody">
            <h4>\(esc(L.s("Como foi conferido", "How it was verified", "Cómo se verificó")))</h4>
            <p>\(esc(method))</p>
            <h4>\(esc(L.s("Cópias", "Copies", "Copias")))</h4>
            <div class="scroll"><table>
              <thead><tr><th>\(esc(L.s("Cartão", "Card", "Tarjeta")))</th><th>\(esc(L.s("Início", "Started", "Inicio")))</th><th>\(esc(L.s("Duração", "Duration", "Duración")))</th><th>\(esc(L.s("Velocidade", "Speed", "Velocidad")))</th><th>\(esc(L.s("Impressão", "Fingerprint", "Huella")))</th><th>\(esc(L.s("Modelo", "Template", "Modelo")))</th><th>\(esc(L.s("Dados", "Data", "Datos")))</th></tr></thead>
              <tbody>
        \(runRows)
              </tbody>
            </table></div>
            <h4>\(esc(L.s("Destinos", "Destinations", "Destinos")))</h4>
            <ul class="paths">\(dests)</ul>
            <h4>\(esc(L.n(fileCount, ("arquivo", "file", "archivo"), ("arquivos", "files", "archivos"))))</h4>
            <input class="search" type="search" placeholder="\(esc(L.s("Filtrar por nome, pasta ou hash", "Filter by name, folder or hash", "Filtrar por nombre, carpeta o hash")))" oninput="cfFilter(this.value)">
            <div class="scroll"><table class="files">
              <thead><tr><th>\(esc(L.s("Arquivo", "File", "Archivo")))</th><th>\(esc(L.s("Tamanho", "Size", "Tamaño")))</th><th>\(esc(L.s("Captura", "Captured", "Captura")))</th><th>xxHash64</th><th>\(esc(L.s("Situação", "Status", "Estado")))</th></tr></thead>
              <tbody>
        \(fileRows)
              </tbody>
            </table></div>
            \(extras)
          </div>
        </details>
        <script>
        function cfFilter(q){q=q.trim().toLowerCase();document.querySelectorAll('table.files tbody tr[data-q]').forEach(function(tr){tr.hidden=q!==''&&tr.dataset.q.indexOf(q)<0;});}
        window.addEventListener('beforeprint',function(){document.querySelectorAll('details').forEach(function(d){d.open=true;});});
        </script>
        """
    }

    func foot() -> String {
        let version = runs.last?.appVersion ?? ""
        return """
        <footer class="muted small">\(esc(L.s("Gerado pelo Cardflow \(version). Este arquivo é refeito a cada cópia deste projeto.",
                                              "Generated by Cardflow \(version). This file is rebuilt after every copy into this project.",
                                              "Generado por Cardflow \(version). Este archivo se rehace con cada copia de este proyecto.")))</footer>
        </main>
        </body>
        </html>
        """
    }

    // MARK: visual

    static let css = """
    :root{--bg:#f5f5f7;--sheet:#fff;--text:#1d1d1f;--muted:#6e6e73;--line:#e2e2e7;--soft:#f2f2f5;--accent:#0071e3;--ok:#1d8236;--ok-bg:#e8f5ec;--warn:#a35400;--warn-bg:#fff3e0;--fail:#d70015;--fail-bg:#fdeced;--sd-body:#3a3a3d;--sd-label:#f4f4f6;--sd-edge:#1d1d1f;--folder:#3c9af0}
    @media (prefers-color-scheme:dark){:root{--bg:#111113;--sheet:#1c1c1e;--text:#f5f5f7;--muted:#98989f;--line:#323236;--soft:#252528;--accent:#2f8cff;--ok:#34c759;--ok-bg:#15291b;--warn:#ff9f0a;--warn-bg:#2e2311;--fail:#ff453a;--fail-bg:#341716;--sd-body:#56565b;--sd-label:#d9d9de;--sd-edge:#0d0d0f;--folder:#4ea5f7}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",system-ui,sans-serif;-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
    main{max-width:840px;margin:0 auto;padding:40px 24px 64px}
    .muted{color:var(--muted)} .small{font-size:13px}
    code{font:12.5px/1.45 ui-monospace,"SF Mono",Menlo,monospace}
    .top{margin-bottom:22px}
    .bar{display:flex;align-items:center;justify-content:space-between;gap:12px}
    .brand{display:flex;align-items:center;gap:8px;font-weight:600;font-size:14px;min-width:0}
    .brand svg{width:22px;height:22px;flex:none}
    .brand .kind{color:var(--muted);font-weight:400;margin-left:4px;padding-left:10px;border-left:1px solid var(--line);white-space:nowrap}
    .print{font:inherit;font-size:13px;color:var(--accent);background:var(--sheet);border:1px solid var(--line);border-radius:99px;padding:5px 13px;cursor:pointer;white-space:nowrap}
    .print:hover{background:var(--soft)}
    h1{font-size:38px;line-height:1.1;letter-spacing:-.022em;margin:26px 0 6px;font-weight:700;overflow-wrap:anywhere}
    .top p{margin:0}
    h2{margin:0;font-size:21px;letter-spacing:-.012em;line-height:1.25}
    h2.sec{font-size:13px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:38px 4px 10px}
    h3{margin:0;font-size:17px;letter-spacing:-.01em}
    h4{margin:24px 0 8px;font-size:14px}
    .hero{border-radius:20px;background:var(--sheet);border:1px solid var(--line);overflow:hidden}
    .verdict{display:flex;gap:16px;align-items:flex-start;padding:22px 24px}
    .vicon svg{width:40px;height:40px;display:block}
    .verdict p{margin:4px 0 0;font-size:15.5px}
    .hero.ok .verdict{background:var(--ok-bg)} .hero.ok h2{color:var(--ok)}
    .hero.warn .verdict{background:var(--warn-bg)} .hero.warn h2{color:var(--warn)}
    .hero.fail .verdict{background:var(--fail-bg)} .hero.fail h2{color:var(--fail)}
    .figures{display:grid;grid-template-columns:repeat(4,1fr);margin:0;border-top:1px solid var(--line)}
    .fig{padding:14px 20px 16px;border-left:1px solid var(--line);min-width:0}
    .fig:first-child{border-left:0}
    .fig dd{margin:0;font-size:26px;font-weight:650;letter-spacing:-.02em;font-variant-numeric:tabular-nums;white-space:nowrap}
    .fig dt{color:var(--muted);font-size:13px}
    .where{list-style:none;margin:0;padding:0;background:var(--sheet);border:1px solid var(--line);border-radius:16px}
    .where li{display:flex;gap:12px;align-items:center;padding:12px 18px;border-top:1px solid var(--line)}
    .where li:first-child{border-top:0}
    .where svg{width:28px;height:22px;flex:none} .where .dev{width:32px;height:32px}
    .where div{min-width:0} .where strong{display:block;font-weight:600}
    .where code{color:var(--muted);overflow-wrap:anywhere}
    .cards{display:grid;gap:10px}
    .card{background:var(--sheet);border:1px solid var(--line);border-radius:16px;padding:16px 20px;scroll-margin-top:24px}
    .card:target{outline:3px solid var(--accent);outline-offset:2px}
    .chead{display:flex;gap:14px;align-items:center;flex-wrap:wrap}
    .chead>svg,.dev{width:40px;height:40px;flex:none}
    .dev{display:block;background:center/contain no-repeat;-webkit-print-color-adjust:exact;print-color-adjust:exact}
    .dev svg{width:100%;height:100%}
    .cname{flex:1 1 180px;min-width:0}
    .counts{display:flex;flex-wrap:wrap;gap:6px;margin:14px 0 0}
    .k{background:var(--soft);border-radius:8px;padding:3px 9px;font-size:13.5px;white-space:nowrap}
    .k strong{font-weight:650;font-variant-numeric:tabular-nums}
    .k.size{background:none;color:var(--muted);padding-left:4px}
    .notes{margin:10px 0 0;padding-left:18px;color:var(--muted);font-size:14px}
    .pill{font-size:12.5px;font-weight:600;padding:4px 10px;border-radius:99px;white-space:nowrap}
    .pill.ok{color:var(--ok);background:var(--ok-bg)} .pill.warn{color:var(--warn);background:var(--warn-bg)} .pill.fail{color:var(--fail);background:var(--fail-bg)}
    .failures{margin-top:12px;padding:12px 14px;border-radius:12px;background:var(--fail-bg);color:var(--fail);font-size:14px}
    .failures ul{margin:6px 0 0;padding-left:18px}
    .tree{background:var(--sheet);border:1px solid var(--line);border-radius:16px;padding:10px 18px}
    .tree ul{list-style:none;margin:0 0 0 7px;padding:0 0 0 14px;border-left:1px solid var(--line)}
    .tree>ul{margin:0;padding:0;border:0}
    .tree li{padding:0}
    .tree .row{display:flex;align-items:baseline;gap:10px;padding:5px 0;flex-wrap:wrap}
    .tree .folder{display:inline-flex;align-items:center;gap:7px;font-weight:500;min-width:0}
    .tree .folder svg{width:16px;height:13px;flex:none}
    .tree .meta{color:var(--muted);font-size:13px;margin-left:auto;font-variant-numeric:tabular-nums;white-space:nowrap}
    details.tech{margin-top:38px;background:var(--sheet);border:1px solid var(--line);border-radius:16px}
    details.tech summary{cursor:pointer;padding:15px 20px;font-weight:600;font-size:15px;list-style:none;display:flex;align-items:center;gap:10px}
    details.tech summary::-webkit-details-marker{display:none}
    details.tech summary::before{content:"";width:6px;height:6px;border-right:2px solid var(--muted);border-bottom:2px solid var(--muted);transform:rotate(-45deg);transition:transform .15s}
    details.tech[open] summary::before{transform:rotate(45deg)}
    details.tech summary .hint{margin-left:auto;font-weight:400;font-size:13px;color:var(--muted)}
    .techbody{padding:2px 20px 20px;border-top:1px solid var(--line)}
    .scroll{overflow-x:auto;border:1px solid var(--line);border-radius:10px}
    table{width:100%;border-collapse:collapse;font-size:13px}
    th{text-align:left;font-weight:600;color:var(--muted);background:var(--soft);padding:8px 10px;white-space:nowrap}
    td{padding:7px 10px;border-top:1px solid var(--line);vertical-align:top}
    td.num{white-space:nowrap;font-variant-numeric:tabular-nums}
    td code{overflow-wrap:anywhere}
    td.nowrap{white-space:nowrap}
    td.path .src{color:var(--muted);font-size:12px;margin-top:2px}
    code.hash{white-space:nowrap}
    tr.group th{background:var(--sheet);color:var(--text);font-size:13.5px;padding-top:14px;border-top:1px solid var(--line)}
    .paths{padding-left:18px;margin:6px 0}
    .search{width:100%;margin:4px 0 10px;padding:9px 12px;border-radius:10px;border:1px solid var(--line);background:var(--soft);color:var(--text);font:inherit}
    a{color:var(--accent)}
    footer{margin-top:36px;text-align:center}
    @media (max-width:640px){main{padding:24px 16px 48px} h1{font-size:30px;margin-top:20px} .figures{grid-template-columns:repeat(2,1fr)} .fig:nth-child(3){border-left:0} .fig:nth-child(n+3){border-top:1px solid var(--line)} .verdict{padding:18px} .brand .kind,details.tech summary .hint{display:none}}
    @media print{body{background:#fff;color:#000} main{padding:0;max-width:none} .print,.search,script{display:none} .card,.hero,.tree,.where,details.tech{break-inside:avoid}}
    """

    static let logo = ##"<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="2" width="18" height="20" rx="4.5" fill="#1d8236"/><path d="M8 12.3l2.7 2.7 5.3-5.6" fill="none" stroke="#fff" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"/></svg>"##
    static let iconOk = ##"<svg viewBox="0 0 44 44" aria-hidden="true"><circle cx="22" cy="22" r="20" fill="var(--ok)"/><path d="M13.5 22.5l6 6 11-12" fill="none" stroke="#fff" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round"/></svg>"##
    static let iconWarn = ##"<svg viewBox="0 0 44 44" aria-hidden="true"><path d="M22 5l18 32H4z" fill="var(--warn)" stroke="var(--warn)" stroke-width="4" stroke-linejoin="round"/><path d="M22 16v10" stroke="#fff" stroke-width="3.4" stroke-linecap="round"/><circle cx="22" cy="31.5" r="2.1" fill="#fff"/></svg>"##
    static let iconFail = ##"<svg viewBox="0 0 44 44" aria-hidden="true"><circle cx="22" cy="22" r="20" fill="var(--fail)"/><path d="M15.5 15.5l13 13M28.5 15.5l-13 13" stroke="#fff" stroke-width="3.4" stroke-linecap="round"/></svg>"##
    /// Reserva quando o ícone do macOS não existe: cartão SD de frente, no desenho do próprio macOS (canto
    /// chanfrado pequeno no alto à direita, faixa amarela na etiqueta, trava amarela à esquerda, sem contatos).
    static let sdGlyph = ##"<svg viewBox="0 0 32 32" aria-hidden="true"><path d="M8.6 2.5h13.9l3.5 3.5v21.6a2 2 0 0 1-2 2H8.6a2 2 0 0 1-2-2V4.5a2 2 0 0 1 2-2z" fill="#4a4a4d"/><path d="M5.9 8.6h.7v3.6h-.7z" fill="#e3a51f"/><path d="M9.6 5.6h12.2l1.6 1.6v18.9a.9.9 0 0 1-.9.9H9.6a.9.9 0 0 1-.9-.9V6.5a.9.9 0 0 1 .9-.9z" fill="#e9e9eb"/><path d="M9.6 5.6h12.2l1.6 1.6V10H8.7V6.5a.9.9 0 0 1 .9-.9z" fill="#e3a51f"/><path d="M20.4 7l1.2 2h-2.4z" fill="#fff"/></svg>"##
    static let driveGlyph = ##"<svg viewBox="0 0 28 22" aria-hidden="true"><rect x="1" y="3" width="26" height="16" rx="4" fill="var(--soft)" stroke="var(--line)" stroke-width="1.2"/><circle cx="21.5" cy="11" r="1.6" fill="var(--ok)"/><path d="M6 11h9" stroke="var(--muted)" stroke-width="1.6" stroke-linecap="round" opacity=".6"/></svg>"##
    static let folderGlyph = ##"<svg viewBox="0 0 16 13" aria-hidden="true"><path d="M1 2.2C1 1.5 1.5 1 2.2 1h3.6l1.6 1.6h6.4c.7 0 1.2.5 1.2 1.2v7.4c0 .7-.5 1.2-1.2 1.2H2.2C1.5 12.4 1 11.9 1 11.2z" fill="var(--folder)"/></svg>"##
}

/// Ícones de dispositivo que vêm no macOS, em PNG pra embutir no relatório. Lidos uma vez por processo.
enum DeviceIcon {
    /// "sd" (também registro antigo, sem tipo), "external" (SSD e HD), "removable" (outros cartões), "folder".
    static func key(for mediaKind: String?) -> String {
        switch mediaKind.flatMap(MediaKind.init(rawValue:)) {
        case .ssd?, .hdd?: return "external"
        case .cfexpressA?, .cfexpressB?, .cfast?, .genericCard?, .recorder?: return "removable"
        case .folder?: return "folder"
        case .sd?, nil: return "sd"
        }
    }

    static func dataURI(_ key: String) -> String? { cache[key] ?? nil }

    private static let cache: [String: String?] = {
        let ext = "/System/Library/Extensions/"
        let files = ["sd": ext + "IOSCSIArchitectureModelFamily.kext/Contents/Resources/SD.icns",
                     "external": ext + "IOStorageFamily.kext/Contents/Resources/External.icns",
                     "internal": ext + "IOStorageFamily.kext/Contents/Resources/Internal.icns",
                     "removable": ext + "IOSCSIArchitectureModelFamily.kext/Contents/Resources/Removable.icns"]
        return files.mapValues { png(icns: $0) }
    }()

    /// PNG de 80 px (40 pt em tela Retina) a partir da maior imagem do .icns.
    static func png(icns path: String, pixels: Int = 80) -> String? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        var best = 0, bestWidth = 0
        for i in 0..<CGImageSourceGetCount(src) {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            if w > bestWidth { best = i; bestWidth = w }
        }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: pixels]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, best, opts as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, nil)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }
}
