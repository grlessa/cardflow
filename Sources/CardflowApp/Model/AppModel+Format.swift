import Foundation
import OffloadKit
import CardFormatKit
import CardFormatXPC

/// Formatação de um cartão: trava de conteúdo (relê o cartão contra os registros) → confirmação →
/// ajudante. O estado mora no `CardSession.formatState`.
extension AppModel {
    /// Dá pra pedir a formatação deste cartão agora? (conferido e liberado, ou tudo já copiado antes)
    func canFormat(_ card: CardSession?) -> Bool {
        guard let card, formattingAvailable else { return false }
        switch card.formatState { case .checking, .formatting, .confirming: return false; default: break }
        if case .finished(let o) = card.phase { return o.canSafelyFormatCard }
        return card.phase == .ready && card.isAlreadyCopied
    }

    /// Botão Formatar: usa o contexto da cópia desta sessão; num cartão que já estava todo copiado (sem
    /// cópia agora), monta o contexto do que está na tela. A trava relê o cartão do mesmo jeito.
    func startFormatFlow(_ card: CardSession) {
        if case .finished = card.phase, card.offloadContext != nil {} else {
            card.offloadContext = currentOffloadContext(for: card)
        }
        requestFormat(card)
    }

    /// Relê o cartão (trava de conteúdo) e vai pra confirmação ou bloqueio. `auto`: confirma sozinho.
    func requestFormat(_ card: CardSession, auto: Bool = false) {
        guard let ctx = card.offloadContext else { return }
        card.formatState = .checking
        Task {
            if let scan = card.scanTask { scan.cancel(); await scan.value }   // não disputa o cartão com a leitura
            let report = await Task.detached {
                try? CardWipeCheck.evaluate(cardRoot: ctx.cardURL, preset: ctx.preset,
                                            choices: ctx.choices, destinations: ctx.destinations)
            }.value
            guard let report else { card.formatState = .failed(.internalError, nil); return }
            guard report.canWipe else { card.formatState = .blocked(report.notVerified); return }
            card.confirmingAutomatically = auto
            card.formatState = .confirming(report)
            if auto { await confirmFormat(card) }
        }
    }

    func cancelFormatConfirmation(_ card: CardSession) {
        if case .confirming = card.formatState { card.formatState = .idle }
    }

    /// Chama o ajudante. Só segue se a trava liberou (`.confirming`) e o disco foi identificado.
    func confirmFormat(_ card: CardSession) async {
        guard case .confirming = card.formatState else { return }
        defer { card.confirmingAutomatically = false }
        guard let ctx = card.offloadContext, let bsd = ctx.wholeDiskBSD,
              let size = PhysicalDisk.wholeDiskSize(bsdName: bsd) else {
            card.formatState = .failed(.deviceRejected, nil); return
        }
        card.formatState = .formatting(.validating)
        let req = FormatRequest(bsdName: bsd, expectedTotalBytes: size, expectedVolumeUUID: ctx.volumeUUID, label: ctx.cardName)
        let resp = await formatter.format(req) { step in card.formatState = .formatting(step) }
        guard resp.ok, let plan = resp.plan else {
            card.formatState = .failed(resp.failure ?? .internalError, resp.detail)
            Notifier.notify(title: String(localized: "format.notif.failTitle"),
                            body: String(localized: "format.notif.failBody \(ctx.cardName)"))
            return
        }
        let rec = CardFormatRecord(at: Date(), fileSystem: plan.fileSystem == .exfat ? "exFAT" : "FAT32",
                                   clusterBytes: plan.clusterBytes, label: ctx.cardName)
        _ = ManifestStore().annotateCardFormatted(rec, manifestJSONPaths: manifestPaths(of: card, ctx: ctx),
                                                  locale: AppLocale.effective)
        card.formatState = .done(plan)
        card.formattedAt = Date()
        reloadHistory()
        if ejectWhenDone { Task { await eject(card) } }   // a opção vale também depois de formatar
        Notifier.notify(title: String(localized: "format.notif.doneTitle"),
                        body: String(localized: "format.notif.doneBody \(ctx.cardName)"))
    }

    /// Registros deste cartão a anotar como formatado: os da cópia desta sessão, ou (cartão que já estava
    /// todo copiado) os registros do projeto que são deste cartão, em cada destino.
    func manifestPaths(of card: CardSession, ctx: OffloadContext) -> [String] {
        if case .finished(let o) = card.phase, !o.manifestPaths.isEmpty { return o.manifestPaths }
        guard let scanned = card.scanned else { return [] }
        let cardFiles = Dictionary(scanned.map { ($0.relPath, $0) }, uniquingKeysWith: { a, _ in a })
        let store = ManifestStore()
        return ctx.destinations.flatMap { dest in
            store.loadAllWithURLs(eventRootIn: dest, eventName: ctx.preset.evento)
                .filter { CopyService.looksLikeSameCard($0.manifest, cardFiles: cardFiles, cardID: card.volume.volumeUUID) }
                .map(\.url.path)
        }
    }
}
