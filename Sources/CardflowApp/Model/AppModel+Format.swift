import Foundation
import OffloadKit
import CardFormatKit
import CardFormatXPC

/// Formatação de um cartão: trava de conteúdo (relê o cartão contra os registros) -> confirmação ->
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
        switch card.formatState {
        case .idle, .failed, .blocked: break
        default: return   // evita reentrada dupla (menu + botão ou automático + clique)
        }
        guard let ctx = card.offloadContext else { return }
        card.formatState = .checking
        Task { [weak self, weak card] in
            guard let self, let card else { return }
            if let scan = card.scanTask { scan.cancel(); await scan.value }   // não disputa o cartão com a leitura
            let report = await Task.detached {
                try? CardWipeCheck.evaluate(cardRoot: ctx.cardURL, preset: ctx.preset,
                                            choices: ctx.choices, destinations: ctx.destinations)
            }.value
            guard self.cards.contains(where: { $0 === card }), case .checking = card.formatState else { return }
            guard let report else { card.formatState = .failed(.internalError, nil); return }
            guard report.canWipe else { card.formatState = .blocked(report.notVerified); return }
            card.confirmingAutomatically = auto
            card.formatState = .confirming(report)
            if auto { await self.confirmFormat(card) }
        }
    }

    func cancelFormatConfirmation(_ card: CardSession) {
        if case .confirming = card.formatState { card.formatState = .idle }
    }

    /// Chama o ajudante. Só segue se a trava liberou (`.confirming`), o disco não foi trocado nem
    /// coincide fisicamente com nenhum destino da cópia.
    func confirmFormat(_ card: CardSession) async {
        guard case .confirming = card.formatState else { return }
        defer { card.confirmingAutomatically = false }
        guard let ctx = card.offloadContext, let bsd = ctx.wholeDiskBSD else {
            card.formatState = .failed(.deviceRejected, nil); return
        }
        // Recusa formatar se o disco físico coincidir com qualquer destino da cópia (ex.: disco multi-partição).
        let destBSDs: [String] = await Task.detached {
            ctx.destinations.compactMap { PhysicalDisk.wholeDiskBSD(for: $0) }
        }.value
        guard !destBSDs.contains(bsd) else {
            card.formatState = .failed(.deviceRejected, "o destino está no mesmo disco físico do cartão")
            return
        }
        // Usa o tamanho capturado no scan/contexto; só consulta em segundo plano se ainda não houver.
        let expectedSize: UInt64?
        if let saved = ctx.wholeDiskBytes ?? card.wholeDiskBytes {
            expectedSize = saved
        } else {
            expectedSize = await Task.detached { PhysicalDisk.wholeDiskSize(bsdName: bsd) }.value
        }
        guard let size = expectedSize else {
            card.formatState = .failed(.deviceRejected, nil); return
        }
        // Confirma que o volume do cartão ainda está no mesmo disco físico antes de disparar o ajudante.
        let currentCardBSD: String? = await Task.detached { PhysicalDisk.wholeDiskBSD(for: ctx.cardURL) }.value
        if let currentCardBSD, currentCardBSD != bsd {
            card.formatState = .failed(.cardChanged, nil); return
        }

        formattingWholeDiskBSDs.insert(bsd)
        card.formatState = .formatting(.validating)
        let req = FormatRequest(bsdName: bsd, expectedTotalBytes: size, expectedVolumeUUID: ctx.volumeUUID, label: ctx.cardName)
        let resp = await formatter.format(req) { step in
            // Impede que um callback de progresso atrasado sobrescreva `.done` ou `.failed`.
            if case .formatting = card.formatState { card.formatState = .formatting(step) }
        }
        guard resp.ok, let plan = resp.plan else {
            formattingWholeDiskBSDs.remove(bsd)
            card.formatState = .failed(resp.failure ?? .internalError, resp.detail)
            Notifier.notify(title: String(localized: "format.notif.failTitle"),
                            body: String(localized: "format.notif.failBody \(ctx.cardName)"))
            return
        }
        let sanitizedLabel = plan.fileSystem == .exfat ? VolumeLabel.exfat(ctx.cardName) : VolumeLabel.fat(ctx.cardName)
        let rec = CardFormatRecord(at: Date(), fileSystem: plan.fileSystem == .exfat ? "exFAT" : "FAT32",
                                   clusterBytes: plan.clusterBytes, label: sanitizedLabel)
        let existingPaths: [String] = {
            if case .finished(let o) = card.phase, !o.manifestPaths.isEmpty { return o.manifestPaths }
            return []
        }()
        let scannedSnapshot = card.scanned ?? []
        let cardUUID = card.volume.volumeUUID
        let locale = AppLocale.effective
        // Atualiza manifestos JSON e regenera relatório HTML fora da thread principal.
        await Task.detached {
            let paths = existingPaths.isEmpty
                ? Self.findManifestPaths(scanned: scannedSnapshot, cardUUID: cardUUID, ctx: ctx)
                : existingPaths
            _ = ManifestStore().annotateCardFormatted(rec, manifestJSONPaths: paths, locale: locale)
        }.value
        card.formatState = .done(plan)
        card.formattedAt = Date()
        if card.remountedAfterFormat { formattingWholeDiskBSDs.remove(bsd) }
        reloadHistory()
        if ctx.ejectWhenDone || ejectWhenDone { Task { await eject(card) } }   // a opção vale também depois de formatar
        Notifier.notify(title: String(localized: "format.notif.doneTitle"),
                        body: String(localized: "format.notif.doneBody \(ctx.cardName)"))
    }

    /// Registros deste cartão a anotar como formatado (puro em I/O, pode rodar em background).
    nonisolated static func findManifestPaths(scanned: [MediaFile], cardUUID: String?, ctx: OffloadContext) -> [String] {
        guard !scanned.isEmpty else { return [] }
        let cardFiles = Dictionary(scanned.map { ($0.relPath, $0) }, uniquingKeysWith: { a, _ in a })
        let store = ManifestStore()
        return ctx.destinations.flatMap { dest in
            store.loadAllWithURLs(eventRootIn: dest, eventName: ctx.preset.evento)
                .filter { CopyService.looksLikeSameCard($0.manifest, cardFiles: cardFiles, cardID: cardUUID) }
                .map(\.url.path)
        }
    }

    func manifestPaths(of card: CardSession, ctx: OffloadContext) -> [String] {
        if case .finished(let o) = card.phase, !o.manifestPaths.isEmpty { return o.manifestPaths }
        return Self.findManifestPaths(scanned: card.scanned ?? [], cardUUID: card.volume.volumeUUID, ctx: ctx)
    }
}
