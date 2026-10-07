import SwiftUI
import OffloadKit
import CardFormatKit
import CardFormatXPC

/// Barra de ação do cartão, presa embaixo do detalhe. Cada estado (pronto, na fila, copiando,
/// conferido, formatando, falhou) aparece aqui, no mesmo lugar, sem empurrar o resto da tela.
struct ActionBar: View {
    @Environment(AppModel.self) private var model
    let card: CardSession

    var body: some View {
        // numa linha sempre que o texto tiver um espaço razoável (ele quebra em duas linhas se precisar);
        // só com a coluna bem estreita o resumo vai pra cima e os controles pra baixo, à direita.
        ActionBarLayout {
            // um contêiner por lado: o layout sempre recebe duas peças, mesmo com um lado vazio
            VStack(alignment: .leading, spacing: 0) { summary }
            HStack(spacing: 10) { controls }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .spacedLabels()
        .frame(maxWidth: 860, minHeight: 64)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .padding(.top, 6)
        .animation(.smooth(duration: 0.25), value: stateKey)
    }

    // MARK: Resumo (esquerda)

    @ViewBuilder private var summary: some View {
        switch card.formatState {
        case .checking: busy("format.checking")
        case .formatting(let step): busy(LocalizedStringKey(FormatResultSection.label(step)))
        case .done(let plan):
            status("action.formatted \(FormatResultSection.fsName(plan)) \(plan.clusterBytes / 1024)",
                   detail: card.ejected ? "action.formatted.removeCard" : nil,
                   symbol: "checkmark.circle.fill", color: .green)
        case .blocked(let paths):
            status("format.blocked.title", detail: "format.blocked.detail \(paths.count)",
                   symbol: "exclamationmark.octagon.fill", color: .red)
        case .failed(let f, let detail):
            status(LocalizedStringKey(FormatResultSection.failure(f)), detail: nil,
                   symbol: "exclamationmark.triangle.fill", color: .orange)
                .help(detail ?? "")
        case .idle, .confirming:
            phaseSummary
        }
    }

    @ViewBuilder private var phaseSummary: some View {
        switch card.phase {
        case .scanning:
            busy("action.scanning")
        case .ready:
            if model.destinationURL == nil {
                status("empty.noDestination.title", detail: "detail.where.none", symbol: "externaldrive.badge.questionmark", color: .orange)
            } else if card.isAlreadyCopied {
                status("action.alreadyCopied", detail: card.alreadyCopiedDetail.map { LocalizedStringKey($0) },
                       symbol: "checkmark.seal.fill", color: .green)
            } else if card.preview == nil {
                busy("main.card.calculating")
            } else if card.isEmpty {
                status("action.empty", detail: "action.empty.detail", symbol: "sdcard", color: .secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.showsRemainingHeadline ? "action.ready.remaining \(Format.bytes(card.headlineBytes))"
                                                     : "action.ready \(Format.bytes(card.headlineBytes))")
                        .font(.headline)
                        .monospacedDigit()
                    if let hint = readyHint {
                        Text(hint).font(.subheadline).foregroundStyle(hintIsWarning ? .orange : .secondary).lineLimit(2)
                    }
                }
            }
        case .queued:
            status("card.status.queuedAt \(model.queuePosition(card) ?? 1)", detail: "action.queued.detail",
                   symbol: "clock", color: .secondary)
        case .running(let p):
            // aviso numa linha, a barra, e os números embaixo (lado a lado eles disputavam espaço e quebravam)
            VStack(alignment: .leading, spacing: 5) {
                Text(card.isCancelling ? "main.running.stopping" : (p.phase == .verifying ? "main.running.verifying" : "main.copying"))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                ProgressView(value: Double(p.bytesDone), total: Double(max(p.bytesTotal, 1)))
                    .progressViewStyle(.linear)
                Text(progressDetail(p)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1)
            }
            .frame(minWidth: 200)
        case .finished(let o):
            if !o.failures.isEmpty {
                status("result.doNotFormat", detail: LocalizedStringKey(String(localized: "count.filesFailed \(o.failures.count)")),
                       symbol: "exclamationmark.octagon.fill", color: .red)
            } else if o.canSafelyFormatCard {
                status("action.verified", detail: verifiedDetail(o), symbol: "checkmark.seal.fill", color: .green)
            } else if o.copiedKeepingCameras {
                status("action.verifiedKept", detail: "action.verifiedKept.detail", symbol: "lock.fill", color: .orange)
            } else {
                status("result.nothingToCopy", detail: "result.reviewBeforeAct", symbol: "questionmark.circle.fill", color: .orange)
            }
        case .failed(let msg, let uncertain):
            status(uncertain ? "result.doNotFormat" : "action.failed.title", detail: LocalizedStringKey(msg),
                   symbol: uncertain ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill",
                   color: uncertain ? .red : .orange)
        }
    }

    // MARK: Controles (direita)

    @ViewBuilder private var controls: some View {
        switch card.formatState {
        case .checking, .formatting: EmptyView()
        case .done: reportButton
        case .blocked: Button("action.backToCard") { card.formatState = .idle }
        case .failed(let f, _):
            if f == .unmountFailed || f == .busy { Button("format.retry") { model.startFormatFlow(card) } }
            Button("action.backToCard") { card.formatState = .idle }
        case .idle, .confirming:
            phaseControls
        }
    }

    @ViewBuilder private var phaseControls: some View {
        switch card.phase {
        case .scanning: EmptyView()
        case .ready:
            if model.destinationURL == nil {
                Button("sidebar.destinations.add") { model.requestAddDestination() }
                    .buttonStyle(.glassProminent)
            } else if card.isAlreadyCopied {
                Button { model.revealCurrentDestinationInFinder() } label: { Label("result.openInFinder", systemImage: "folder") }
                    .labelStyle(.iconOnly).help("result.openInFinder")
                formatOrEjectButtons
            } else if card.preview == nil {
                EmptyView()
            } else if card.isEmpty {
                ejectButton
            } else {
                AutoFormatToggle()
                    .disabled(!card.excludedCameras.isEmpty)   // câmera de fora: formatar fica travado
                if card.showsVerifiedResumeOption {
                    Button("main.resume.verifyAll") { model.enqueueCopy(card, fastResume: false) }
                        .help(String(localized: "main.resume.verifiedHelp"))
                        .disabled(!model.canStart(card))
                }
                Button { model.enqueueCopy(card) } label: {
                    Text(card.isResume ? "action.resume" : "action.copy").frame(minWidth: 130)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canStart(card))
            }
        case .queued:
            Button("action.removeFromQueue") { model.dequeue(card) }
        case .running:
            Button(role: .cancel) { model.cancelOffload(card) } label: { Label("main.running.stop", systemImage: "stop.fill") }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(card.isCancelling)
        case .finished(let o):
            if !o.failures.isEmpty {
                reportButton
                Button("action.tryAgain") { model.enqueueCopy(card) }
                    .buttonStyle(.glassProminent)
                    .disabled(!model.canStart(card))
            } else if o.canSafelyFormatCard {
                Button { model.revealOffloadInFinder(o) } label: { Label("result.openInFinder", systemImage: "folder") }
                    .labelStyle(.iconOnly).help("result.openInFinder")
                reportButton
                formatOrEjectButtons
            } else if o.copiedKeepingCameras {
                Button { model.revealOffloadInFinder(o) } label: { Label("result.openInFinder", systemImage: "folder") }
                    .labelStyle(.iconOnly).help("result.openInFinder")
                reportButton
                ejectButton
            } else {
                ejectButton
            }
        case .failed:
            Button("action.tryAgain") { model.enqueueCopy(card) }
                .buttonStyle(.glassProminent)
                .disabled(!model.canStart(card))
        }
    }

    private var hintIsWarning: Bool {
        card.loteLossUnconfirmed || model.hasShortfall(model.destinationURL, card: card)
            || model.hasShortfall(model.backupURL, card: card) || model.internalPermissionDenied
    }
    private var readyHint: String? {
        if card.loteLossUnconfirmed { return String(localized: "action.hint.loteUnconfirmed") }
        if model.hasShortfall(model.destinationURL, card: card) || model.hasShortfall(model.backupURL, card: card) {
            return String(localized: "main.dest.noSpace")
        }
        if model.internalPermissionDenied { return String(localized: "main.dest.permissionDenied") }
        if let h = card.resumeActionHint { return h }
        let dests = model.offloadDestinations.compactMap { model.volume($0)?.name }
        guard !dests.isEmpty else { return nil }
        return String(localized: "action.ready.to \(ListFormatter.localizedString(byJoining: dests))")
    }

    // MARK: Copiando


    private func progressDetail(_ p: OffloadProgress) -> String {
        var parts = [String(localized: "action.progress.bytes \(Format.bytes(p.bytesDone)) \(Format.bytes(p.bytesTotal))")]
        if let start = card.startedAt, p.bytesDone > 0 {
            let elapsed = Date().timeIntervalSince(start)
            let rate = Double(p.bytesDone) / max(elapsed, 1)
            parts.append(String(localized: "action.progress.rate \(Format.bytes(Int64(rate)))"))
            if p.bytesTotal > p.bytesDone, rate > 0 {
                parts.append(String(localized: "action.progress.left \(Format.elapsed(Double(p.bytesTotal - p.bytesDone) / rate))"))
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Terminou


    private func verifiedDetail(_ o: OffloadOutcome) -> LocalizedStringKey {
        if card.ejected { return "action.verified.ejected" }
        let count = String(localized: "count.filesVerified \(o.verifiedCount)")
        if let e = card.lastElapsed { return LocalizedStringKey(count + " " + String(localized: "action.inTime \(Format.elapsed(e))")) }
        return LocalizedStringKey(count)
    }

    // MARK: Botões comuns

    @ViewBuilder private var reportButton: some View {
        if case .finished(let o) = card.phase, !o.manifestPaths.isEmpty {
            Button { model.openReport(o) } label: { Label("action.report", systemImage: "doc.text") }
        }
    }

    @ViewBuilder private var formatOrEjectButtons: some View {
        if model.formattingAvailable {
            if !card.ejected {
                ejectButton
                Button("format.button") { model.startFormatFlow(card) }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .disabled(!model.canFormat(card))
            }
        } else {
            if !card.ejected { ejectButton }
            if model.formatter.permission != .unavailable {
                SettingsLink { Text("format.activate.link") }
                    .help("action.activateFormat.help")
            }
        }
    }

    @ViewBuilder private var ejectButton: some View {
        if !card.ejected {
            Button { Task { await model.eject(card) } } label: { Label("format.eject", systemImage: "eject") }
                .disabled(card.isBusy)
                .help(card.ejectError.map { String(localized: "result.eject.inUse") + " (\($0))" } ?? "")
        }
    }

    // MARK: Peças

    private func status(_ title: LocalizedStringKey, detail: LocalizedStringKey?, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
    }

    private func busy(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(title).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var stateKey: String {
        "\(card.phase)|\(card.formatState)"
    }
}

/// Resumo à esquerda e controles à direita. Os controles ficam com a largura que pedem; o resumo usa o resto
/// e quebra linha. Só empilha quando sobra menos que `minSummary` pro resumo (o `ViewThatFits` empilhava
/// assim que a frase inteira não cabia numa linha).
struct ActionBarLayout: Layout {
    var spacing: CGFloat = 14
    var minSummary: CGFloat = 200
    var stackSpacing: CGFloat = 10

    private func inline(_ width: CGFloat, controls: CGSize) -> Bool { width - controls.width - spacing >= minSummary }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let c = subviews[1].sizeThatFits(.unspecified)
        guard let w = proposal.width, w.isFinite else {
            let sIdeal = subviews[0].sizeThatFits(.unspecified)
            return CGSize(width: sIdeal.width + spacing + c.width, height: max(sIdeal.height, c.height))
        }
        if inline(w, controls: c) {
            let sh = subviews[0].sizeThatFits(ProposedViewSize(width: w - c.width - spacing, height: nil))
            return CGSize(width: w, height: max(sh.height, c.height))
        }
        let sh = subviews[0].sizeThatFits(ProposedViewSize(width: w, height: nil))
        return CGSize(width: w, height: sh.height + stackSpacing + c.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let c = subviews[1].sizeThatFits(.unspecified)
        if inline(bounds.width, controls: c) {
            let sw = bounds.width - c.width - spacing
            let sh = subviews[0].sizeThatFits(ProposedViewSize(width: sw, height: nil))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY - sh.height / 2), proposal: ProposedViewSize(width: sw, height: sh.height))
            subviews[1].place(at: CGPoint(x: bounds.maxX - c.width, y: bounds.midY - c.height / 2), proposal: ProposedViewSize(c))
        } else {
            let sh = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: ProposedViewSize(width: bounds.width, height: sh.height))
            subviews[1].place(at: CGPoint(x: bounds.maxX - c.width, y: bounds.minY + sh.height + stackSpacing), proposal: ProposedViewSize(c))
        }
    }
}

