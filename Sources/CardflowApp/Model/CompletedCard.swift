import Foundation
import OffloadKit

/// Resumo de um cartão que terminou e saiu do Mac: o que aconteceu, a que horas e onde ficou. Fica na tela
/// até a pessoa fechar ou outro cartão chegar, pra quem volta do café ver que deu certo em vez de uma tela
/// vazia. Só existe quando o app de fato fez algo com o cartão e terminou bem.
struct CompletedCard: Identifiable, Equatable {
    struct Step: Equatable {
        enum Kind: Equatable { case copied, alreadyThere, verified, formatted, ejected }
        /// Com o cartão ainda conectado, formatar e ejetar podem estar em andamento ou por fazer.
        enum State: Equatable { case done, running, pending }
        let kind: Kind
        let at: Date?
        var state: State = .done
    }
    enum Verdict: Equatable {
        case ready       // tudo salvo: pode tirar (e, se formatou, já pode voltar pra câmera)
        case keepCard    // copiado, mas uma câmera ficou no cartão por escolha: não formatar
    }

    let id: String
    let name: String
    let mediaKind: MediaKind
    let files: Int
    let bytes: Int64
    let destinations: [URL]
    let steps: [Step]
    let verdict: Verdict
    let fileSystem: String?
    let manifestPaths: [String]
    /// Caminho das pastas no destino (o mesmo "Vai para" da tela do cartão).
    let pathSegments: [String]

    var formatted: Bool { steps.contains { $0.kind == .formatted && $0.state == .done } }
    var ejected: Bool { steps.contains { $0.kind == .ejected && $0.state == .done } }
    var formatting: Bool { steps.contains { $0.kind == .formatted && $0.state == .running } }

    /// `live`: o cartão ainda está conectado; formatar (se a formatação estiver ativada) e ejetar entram como
    /// etapas em andamento ou por fazer, pra nada do fim do processo ficar escondido.
    @MainActor
    static func make(from card: CardSession, destinations: [URL], manifestPaths: [String] = [],
                     live: Bool = false, formattingAvailable: Bool = false) -> CompletedCard? {
        var steps: [Step] = []
        var verdict = Verdict.ready
        var paths = manifestPaths
        var files = card.preview?.selectedCount ?? 0

        switch card.phase {
        case .finished(let o):
            guard o.canSafelyFormatCard || o.copiedKeepingCameras else { return nil }
            if o.copiedKeepingCameras { verdict = .keepCard }
            if !o.manifestPaths.isEmpty { paths = o.manifestPaths }
            files = o.verifiedCount + o.skipped.count
            steps.append(Step(kind: .copied, at: card.finishedAt))
            steps.append(Step(kind: .verified, at: card.finishedAt))
        case .ready where card.isAlreadyCopied:
            steps.append(Step(kind: .alreadyThere, at: nil))
        default:
            return nil
        }

        var fileSystem: String?
        switch card.formatState {
        case .done(let plan):
            fileSystem = plan.fileSystem == .exfat ? "exFAT" : "FAT32"
            steps.append(Step(kind: .formatted, at: card.formattedAt))
        case .checking, .formatting:
            if live { steps.append(Step(kind: .formatted, at: nil, state: .running)) }
        default:   // inclui .confirming: a confirmação está aberta esperando a pessoa
            if live && verdict == .ready && formattingAvailable { steps.append(Step(kind: .formatted, at: nil, state: .pending)) }
        }
        if card.ejected { steps.append(Step(kind: .ejected, at: card.ejectedAt)) }
        else if live { steps.append(Step(kind: .ejected, at: nil, state: .pending)) }

        // Cartão que já estava todo no destino e nada foi feito com ele agora: não é uma conclusão
        // (conectado, segue a tela de sempre; tirado do Mac, não deixa resumo).
        if steps.first?.kind == .alreadyThere, !steps.dropFirst().contains(where: { $0.state != .pending }) { return nil }

        return CompletedCard(id: UUID().uuidString, name: card.volume.name, mediaKind: card.volume.mediaKind,
                             files: files, bytes: card.preview?.totalBytes ?? 0, destinations: destinations,
                             steps: steps, verdict: verdict, fileSystem: fileSystem, manifestPaths: paths,
                             pathSegments: card.pathSegments)
    }
}

extension CardSession {
    /// Caminho até onde os arquivos caem: segue a árvore enquanto ela tem um galho só; na bifurcação,
    /// junta os nomes ("Foto · Vídeo").
    var pathSegments: [String] {
        var out: [String] = []
        var level = tree
        while !level.isEmpty {
            if level.count == 1 {
                out.append(level[0].name)
                level = level[0].children ?? []
            } else {
                out.append(level.map(\.name).joined(separator: " · "))
                break
            }
        }
        return out
    }
}
