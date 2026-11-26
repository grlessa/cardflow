import Foundation
import AppKit
import OffloadKit

/// Cópia de cada cartão, pela fila serial. O contexto (modelo, projeto, mídia, filtro, destinos, câmera,
/// formatar e ejetar ao terminar) é congelado ao enfileirar.
extension AppModel {
    /// Dá pra começar a cópia deste cartão agora?
    func canStart(_ card: CardSession) -> Bool {
        switch card.phase { case .ready, .failed, .finished: break; default: return false }
        if case .formatting = card.formatState { return false }
        guard destinationURL != nil else { return false }
        if internalPermissionDenied { return false }   // macOS bloqueou a pasta interna
        if card.loteLossUnconfirmed { return false }    // lote anterior incompleto não confirmado
        guard let sf = card.preview?.shortfalls else { return false }   // prévia ainda não chegou
        if card.isAlreadyCopied { return false }
        return sf.isEmpty
    }

    /// Algum destino (principal/backup) não cabe o que este cartão precisa?
    func hasShortfall(_ url: URL?, card: CardSession?) -> Bool {
        guard let url, let sf = card?.preview?.shortfalls else { return false }
        let path = Self.normalizeFolderURL(url).path
        return sf.contains { Self.normalizeFolderURL($0.destination).path == path }
    }

    /// Contexto da cópia a partir do que está na tela agora: as mesmas escolhas que a cópia usaria.
    func currentOffloadContext(for card: CardSession, fastResume: Bool = true) -> OffloadContext? {
        let dests = offloadDestinations
        guard !dests.isEmpty else { return nil }
        var session = sessionValues
        session["camera"] = card.camera
        return OffloadContext(cardURL: card.volume.url, cardName: card.volume.name,
                              wholeDiskBSD: card.volume.physicalDeviceID, volumeUUID: card.volume.volumeUUID,
                              preset: previewPreset,
                              choices: WipeChoices(chosenMedia: effectiveMedia(card), capturedIn: card.capturedIn,
                                                   excludedGroups: card.excludedGroups),
                              destinations: dests, wholeDiskBytes: card.wholeDiskBytes,
                              camera: usesCameraToken ? card.camera : "",
                              cameras: card.camerasByGroup, sessionValues: session,   // nomes sempre: o relatório diz quais câmeras ficaram
                              fastResume: fastResume, formatWhenDone: autoFormatThisSession,
                              ejectWhenDone: ejectWhenDone,
                              internalDestinations: Set(dests.filter { isInternalDestination($0) }))
    }

    /// O que acontece sozinho depois de conferir. Formatar e ejetar ao terminar são opções independentes:
    /// formatar (só com tudo salvo) vem antes e, depois dele, ejeta se a opção pedir; sem nenhuma das duas,
    /// o cartão fica na tela com os botões. Câmera deixada de fora: nunca formata, mas pode ejetar.
    enum AfterCopy: Equatable { case format, eject, stay }

    nonisolated static func afterCopy(safe: Bool, keptCameras: Bool, formatOn: Bool, formattingAvailable: Bool,
                                      ejectOn: Bool) -> AfterCopy {
        if safe && formatOn && formattingAvailable { return .format }
        if (safe || keptCameras) && ejectOn { return .eject }
        return .stay
    }

    /// Mídia que ficará no cartão sem cópia, quando o automático está ligado E pode de fato rodar.
    func autoFormatWarning(_ card: CardSession?) -> [FileType: Int]? {
        guard autoFormatThisSession, formattingAvailable,
              card?.excludedCameras.isEmpty == true,
              let ex = card?.preview?.excludedByChoice, !ex.isEmpty else { return nil }
        return ex
    }

    func enqueueCopy(_ card: CardSession, fastResume: Bool = true) {
        guard canStart(card), let ctx = currentOffloadContext(for: card, fastResume: fastResume) else { return }
        card.offloadContext = ctx
        card.formatState = .idle
        card.ejected = false; card.ejectError = nil
        card.isCancelling = false
        card.frozenPathSegments = nil; card.frozenTotalBytes = nil
        card.phase = .queued
        if queue.isIdle { batchCount = 0; batchSucceeded = 0 }
        batchCount += 1
        queue.enqueue(card.sessionID.uuidString)
    }

    /// Enfileira todos os cartões prontos, na ordem da barra lateral.
    func enqueueAll() { for c in cards where isFreshReady(c) { enqueueCopy(c) } }
    var readyToCopyCount: Int { cards.filter(isFreshReady).count }
    /// Pronto e ainda não copiado: "Copiar todos" não repete cartão já conferido nem vazio.
    func isFreshReady(_ c: CardSession) -> Bool {
        c.phase == .ready && !c.isAlreadyCopied && !c.isEmpty && canStart(c)
    }

    /// Tira da fila de espera e volta a "pronto".
    func dequeue(_ card: CardSession) {
        guard card.phase == .queued else { return }
        queue.remove(card.sessionID.uuidString)
        batchCount = max(0, batchCount - 1)
        card.phase = .ready
        recomputePreview(card)
    }

    func queuePosition(_ card: CardSession) -> Int? { queue.position(of: card.sessionID.uuidString) }

    /// Executa a cópia de um cartão (chamado pela fila; volta quando terminar, falhar ou parar).
    func runOffload(sessionID: String) async {
        guard let card = card(sessionID: sessionID), card.phase == .queued, let ctx = card.offloadContext else { return }
        card.startedAt = Date(); card.lastElapsed = nil
        card.phase = .running(OffloadProgress(phase: .scanning, filesDone: 0, filesTotal: 0, bytesDone: 0, bytesTotal: 0))
        let media = ctx.choices.chosenMedia
        let task = Task.detached { [weak self] in
            let service = CopyService(preset: ctx.preset, spaceProvider: VolumeFreeSpace(), locale: AppLocale.effective)
            do {
                let outcome = try service.run(
                    cardRoot: ctx.cardURL, chosenMedia: media, destinations: ctx.destinations, camera: ctx.camera,
                    cameras: ctx.cameras, excludedGroups: ctx.choices.excludedGroups,
                    sessionValues: ctx.sessionValues, capturedIn: ctx.choices.capturedIn,
                    fastResume: ctx.fastResume, internalDestinations: ctx.internalDestinations,
                    isCancelled: { Task.isCancelled },   // Parar cancela este Task -> checado entre blocos
                    onProgress: { p in Task { @MainActor in card.applyProgress(p) } })
                await self?.finishOffload(card, outcome)
            } catch let error as OffloadError {
                if case .cancelled = error {
                    await self?.returnToStartAfterStop(card)
                } else {
                    let isPermission: Bool = { if case .permissionDenied = error { return true } else { return false } }()
                    let cardSafe = isPermission || { if case .notEnoughSpace = error { return true } else { return false } }()
                    await self?.failOffload(card, message: AppModel.localizedMessage(for: error),
                                            cardUncertain: !cardSafe,
                                            permissionDeniedOnInternal: isPermission && !ctx.internalDestinations.isEmpty)
                }
            } catch let error as NamingError {
                await self?.failOffload(card, message: AppModel.localizedMessage(for: error), cardUncertain: false)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.failOffload(card, message: msg, cardUncertain: true)
            }
        }
        card.offloadTask = task
        await task.value
        card.offloadTask = nil
        if queue.order.isEmpty {
            if batchSucceeded > 1 {
                Notifier.notify(title: String(localized: "notif.queueDoneTitle"),
                                body: String(localized: "notif.queueDoneBody \(batchSucceeded)"))
            }
            batchCount = 0
            batchSucceeded = 0
        }
    }

    private func finishOffload(_ card: CardSession, _ outcome: OffloadOutcome) {
        if let s = card.startedAt { card.lastElapsed = Date().timeIntervalSince(s) }
        card.frozenPathSegments = card.pathSegments
        card.frozenTotalBytes = card.preview?.totalBytes
        card.phase = .finished(outcome)
        card.finishedAt = Date()
        if outcome.canSafelyFormatCard || outcome.copiedKeepingCameras {
            batchSucceeded += 1
        }
        reloadHistory()
        refreshDiskSpaces()
        // decisão ÚNICA (afterCopy): formatar e ejetar ao terminar, cada um pela sua opção congelada no contexto.
        let ejectOn = card.offloadContext?.ejectWhenDone ?? ejectWhenDone
        switch Self.afterCopy(safe: outcome.canSafelyFormatCard, keptCameras: outcome.copiedKeepingCameras,
                              formatOn: card.offloadContext?.formatWhenDone == true,
                              formattingAvailable: formattingAvailable, ejectOn: ejectOn) {
        case .format: requestFormat(card, auto: true)   // ejeta depois de formatar, se a opção pedir
        case .eject: Task { await eject(card) }
        case .stay: break
        }
        notifyFinished(outcome, cardName: card.volume.name)
        if Preferences.opensReportWhenDone, outcome.canSafelyFormatCard || outcome.copiedKeepingCameras || !outcome.failures.isEmpty {
            openReport(outcome)
        }
    }

    private func failOffload(_ card: CardSession, message: String, cardUncertain: Bool, permissionDeniedOnInternal: Bool = false) {
        if permissionDeniedOnInternal { internalPermissionDenied = true }
        card.phase = .failed(message, cardUncertain: cardUncertain)
        card.isCancelling = false
        notifyFailed(uncertain: cardUncertain, cardName: card.volume.name)
    }

    /// Volta a "pronto" depois de Parar: relê a prévia (vira "Retomar"). Cancelar não é falha.
    func returnToStartAfterStop(_ card: CardSession) {
        card.isCancelling = false
        card.phase = .ready
        card.startedAt = nil; card.lastElapsed = nil
        recomputePreview(card)
    }

    /// Para a cópia (ou tira da fila, se ainda não começou).
    func cancelOffload(_ card: CardSession) {
        if card.phase == .queued { dequeue(card); return }
        guard card.isRunning else { return }
        card.isCancelling = true   // feedback imediato (o encerramento espera o fim do bloco atual)
        card.offloadTask?.cancel()
    }

    /// Ejeta o cartão em segundo plano (nunca bloqueia a thread principal esperando buffers/Spotlight).
    func eject(_ card: CardSession) async {
        if let scan = card.scanTask { scan.cancel(); await scan.value }
        let url = card.volume.url
        let errorMessage: String? = await Task.detached {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let errorMessage {
            card.ejected = false; card.ejectError = errorMessage
        } else {
            card.ejected = true; card.ejectError = nil; card.ejectedAt = Date()
        }
    }

    // MARK: Avisos do sistema

    func notifyFinished(_ outcome: OffloadOutcome, cardName: String) {
        if !outcome.failures.isEmpty {
            Notifier.notify(title: String(localized: "notif.failTitle"),
                            body: String(localized: "notif.failBody \(cardName) \(outcome.failures.count)"))
        } else if outcome.canSafelyFormatCard {
            Notifier.notify(title: String(localized: "notif.doneTitle"),
                            body: String(localized: "notif.doneBody \(cardName)"))
        } else if outcome.copiedKeepingCameras {
            Notifier.notify(title: String(localized: "notif.doneTitle"),
                            body: String(localized: "notif.doneKeptBody \(cardName)"))
        }
    }

    func notifyFailed(uncertain: Bool, cardName: String) {
        if uncertain {
            Notifier.notify(title: String(localized: "notif.interruptedTitle"),
                            body: String(localized: "notif.interruptedBody \(cardName)"))
        } else {
            Notifier.notify(title: String(localized: "notif.notDoneTitle"),
                            body: String(localized: "notif.notDoneBody \(cardName)"))
        }
    }

    // MARK: Relatório e Finder

    /// Abre o relatório do projeto (`<projeto>/Relatório Cardflow.html`) já na seção deste cartão. Se não
    /// existir (cópia de versão antiga), gera fora da thread principal a partir dos registros do projeto.
    func openReport(manifestPaths: [String]) {
        guard let jsonPath = manifestPaths.first else { return }
        let json = URL(fileURLWithPath: jsonPath)
        let locale = AppLocale.effective
        Task.detached {
            let store = ManifestStore()
            var report = store.reportURL(forManifestJSON: json, locale: locale)
            if !FileManager.default.fileExists(atPath: report.path) {
                let project = json.deletingLastPathComponent().deletingLastPathComponent()
                guard let made = try? store.writeProjectReport(eventRootIn: project.deletingLastPathComponent(),
                                                               eventName: project.lastPathComponent,
                                                               locale: locale) else {
                    await MainActor.run { _ = NSWorkspace.shared.open(json) }
                    return
                }
                report = made
            }
            let finalReport = report
            let id8 = json.deletingPathExtension().lastPathComponent.split(separator: "-").last.map(String.init) ?? ""
            var comps = URLComponents(url: finalReport, resolvingAgainstBaseURL: false)
            comps?.fragment = "cartao-" + id8
            let target = comps?.url ?? finalReport
            await MainActor.run {
                if let browser = NSWorkspace.shared.urlForApplication(toOpen: finalReport) {
                    NSWorkspace.shared.open([target], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    NSWorkspace.shared.open(finalReport)
                }
            }
        }
    }
    func openReport(_ outcome: OffloadOutcome) { openReport(manifestPaths: outcome.manifestPaths) }

    /// Abre a pasta do projeto no destino: ver os arquivos com os próprios olhos antes de formatar.
    func revealOffloadInFinder(_ outcome: OffloadOutcome) {
        if let first = outcome.manifestPaths.first {
            NSWorkspace.shared.open(URL(fileURLWithPath: first).deletingLastPathComponent().deletingLastPathComponent())
        } else if let d = destinationURL {
            NSWorkspace.shared.open(d)
        }
    }

    func revealCurrentDestinationInFinder() {
        guard let destinationURL else { return }
        NSWorkspace.shared.open(destinationURL)
    }

    func revealInFinder(_ card: CardSession) {
        NSWorkspace.shared.activateFileViewerSelecting([card.volume.url])
    }
}

extension CardSession {
    /// Ignora progresso fora de ordem (Tasks não estruturadas não preservam a ordem de entrega); senão a
    /// barra recuaria e passaria sensação de travamento.
    func applyProgress(_ p: OffloadProgress) {
        guard case .running(let cur) = phase else { return }
        if p.phase.order > cur.phase.order || (p.phase == cur.phase && p.bytesDone >= cur.bytesDone) {
            phase = .running(p)
        }
    }
}
