import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OffloadKit

struct MainView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var updates: UpdateController
    @State private var editor: PresetEditorModel?
    @State private var confirmDelete = false
    @State private var importError = false
    @State private var showingHistory = false
    @State private var showingOnboarding = false
    @State private var ignoredFilesSheet: IgnoredFilesSheet?
    @State private var showingCaptureFilter = false
    @State private var filterDraftMode: CaptureDateFilterDraftMode = .all
    @State private var filterSingleDay = Date()
    @State private var filterRangeStart = Date()
    @State private var filterRangeEnd = Date()

    /// Tamanhos derivados da janela: cards crescem na largura e ícone/números/seta escalam.
    private struct Metrics {
        let cardW: CGFloat
        let cardH: CGFloat
        let icon: CGFloat
        let name: CGFloat
        let gb: CGFloat
        let arrow: CGFloat
        let gap: CGFloat
        init(_ size: CGSize) {
            // s = 1 no tamanho mínimo, sobe até 1.35 conforme a janela cresce (escala o que é visual).
            let s = min(max(min(size.width / 1180, size.height / 760), 1.0), 1.35)
            // largura proporcional (piso 250 / teto 540): nunca encosta na borda nem estica demais.
            cardW = min(max(size.width * 0.31, 250), 540)
            cardH = min(max(size.height - 240, 430), 560)   // teto maior pra o card cheio respirar (status + complemento + filtros)
            icon = cardH * 0.16                              // proporcional à ALTURA do card — cresce junto quando o card é maior
            name = 22 * s
            gb = 25 * s
            arrow = 30 * s
            gap = 24 * s
        }
    }

    private enum CaptureDateFilterDraftMode: Hashable {
        case all
        case today
        case singleDay
        case range
    }

    // TOPO — seletor de preset, gerenciamento, histórico e ajuda. Extraído do body pra o
    // type-checker não engasgar com a expressão gigante da tela inteira.
    @ViewBuilder private var presetBar: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Text("main.preset.label").font(.callout).foregroundStyle(.secondary).fixedSize()
            Picker("", selection: $model.selectedPresetId) {
                ForEach(model.presets, id: \.id) { p in presetLabel(p).tag(p.id) }
            }
            .labelsHidden().fixedSize().disabled(model.isBusy)
            Button { openEditor(.editing(model.activePreset)) } label: {
                Label("main.preset.editButton", systemImage: "pencil").labelStyle(.titleAndIcon)
            }
                .help("main.preset.edit.help").disabled(model.isBusy)
            Button { openEditor(.creating()) } label: {
                Label("main.preset.newButton", systemImage: "plus").labelStyle(.titleAndIcon)
            }
                .help("main.preset.new.help").disabled(model.isBusy)
            Menu {
                Button("main.preset.import") { importPresetPanel() }
                Button("main.preset.export") { exportPresetPanel() }
                Button("main.preset.duplicate") { model.duplicateActivePreset() }
                Divider()
                Button("main.preset.delete", role: .destructive) { confirmDelete = true }
                    .disabled(model.selectedPresetId == "factory-default")
            } label: { Image(systemName: "ellipsis") }
            .menuIndicator(.hidden).help("main.preset.manage.help").disabled(model.isBusy)
            .confirmationDialog(Text("main.preset.deleteConfirm \(displayName(model.activePreset))"),
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("main.preset.delete", role: .destructive) { model.deleteActivePreset() }
                Button("main.cancel", role: .cancel) {}
            }
            .alert("main.importError", isPresented: $importError) {
                Button("main.ok", role: .cancel) {}
            }
            Spacer()
            Button { showingHistory = true } label: { Label("main.history.button", systemImage: "clock.arrow.circlepath") }
                .help("main.history.help").disabled(model.destinationURL == nil).fixedSize()
            Button { showingOnboarding = true } label: { Image(systemName: "questionmark.circle") }
                .help("main.onboarding.help")
        }
    }

    // Rótulo do preset no seletor: o de FÁBRICA é exibido localizado (PT "Padrão", EN "Default",
    // ES "Predeterminado"); presets do usuário ficam verbatim. Só a EXIBIÇÃO muda — o dado salvo
    // (name="Padrão", id="factory-default") não é tocado, pra não quebrar persistência/round-trip.
    @ViewBuilder private func presetLabel(_ p: Preset) -> some View {
        if p.id == Preset.factoryDefault.id {
            Text("preset.factory.name")
        } else {
            Text(verbatim: p.name)
        }
    }

    // Nome do preset para mensagens (ex.: confirmar exclusão): localiza só o de fábrica.
    private func displayName(_ p: Preset) -> String {
        p.id == Preset.factoryDefault.id ? String(localized: "preset.factory.name") : p.name
    }

    // abre o editor já sabendo os nomes dos OUTROS presets (pra avisar nome duplicado, #23).
    private func openEditor(_ ed: PresetEditorModel) {
        ed.otherNames = Set(model.presets.filter { $0.id != ed.draft.id }.map(\.name))
        editor = ed
    }

    private func enforceMinimumWindowSize() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
            let minimum = NSSize(width: AppWindowSize.minimum.width, height: AppWindowSize.minimum.height)
            window.minSize = minimum
            window.contentMinSize = minimum

            let current = window.contentView?.bounds.size ?? window.frame.size
            guard current.width < minimum.width || current.height < minimum.height else { return }
            let target = NSSize(width: max(current.width, minimum.width), height: max(current.height, minimum.height))
            window.setContentSize(target)
            window.center()
        }
    }

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            let m = Metrics(geo.size)
            VStack(spacing: 14) {
                updateBannerArea
                presetBar.padding(.top, 16)   // TOPO — preset + histórico + ajuda

                // MEIO — cartão → fluxo → destino (cards crescem com a janela)
                HStack(alignment: .center, spacing: m.gap) {
                    cardPanel(model, m)
                    TransferFlow(state: model.state, canStart: model.canStart, arrow: m.arrow, startedAt: model.offloadStartedAt)
                    destPanel(model, m)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.smooth(duration: 0.35), value: model.detectedCard?.id)

                // BAIXO — ação / resultado
                bottomBar(model)
                    .padding(.bottom, 40)
                    .animation(.smooth(duration: 0.3), value: stateKey(model.state))
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // Segue o tema do sistema: base do sistema + um leve banho de acento (sutil, adaptativo).
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    LinearGradient(colors: [Color.accentColor.opacity(0.07), .clear, Color.accentColor.opacity(0.05)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .ignoresSafeArea()
            }
        }
        .frame(minWidth: AppWindowSize.minimum.width, minHeight: AppWindowSize.minimum.height)
        .onChange(of: model.selectedPresetId) { model.presetSelectionChanged() }
        .onChange(of: model.watcher.volumes) { model.reconcileVolumes() }
        .onChange(of: model.detectedCard?.id) { model.refreshCardPreview() }
        .onChange(of: model.mediaChoice) { model.refreshCardPreview() }
        .onChange(of: model.destinationURL) { model.refreshCardPreview() }
        .onChange(of: model.backupURL) { model.refreshCardPreview() }
        .sheet(isPresented: $showingHistory) {
            HistoryView(manifests: model.loadHistory(), onClose: { showingHistory = false })
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(onClose: { showingOnboarding = false })
        }
        .sheet(item: $ignoredFilesSheet) { sheet in
            IgnoredFilesView(paths: sheet.paths) {
                ignoredFilesSheet = nil
            }
        }
        .onAppear {
            enforceMinimumWindowSize()
            if !UserDefaults.standard.bool(forKey: "cardflow.didOnboard") {
                UserDefaults.standard.set(true, forKey: "cardflow.didOnboard")
                showingOnboarding = true
            }
        }
        .sheet(item: $editor) { ed in
            PresetEditorView(
                model: ed,
                onSave: {
                    if ed.save(into: model.presetStore) {
                        // preset NOVO: trata como seleção (reseta a Pasta/campos pro evento do novo preset, e
                        // o preview/Iniciar passam a refletir ele na hora). Edição: preserva o que foi digitado.
                        model.reloadPresets(selecting: ed.draft.id, preserveContext: !ed.isNew)
                        model.savePresetSelection()   // lembra o preset salvo/criado na sessão
                        editor = nil                  // só fecha quando REALMENTE salvou
                    } else {
                        // #9: não fecha a sheet — senão a configuração inteira do voluntário sumiria sem aviso.
                        ed.saveError = String(localized: "preset.saveError")
                    }
                },
                onCancel: { editor = nil },
                onDelete: {
                    try? model.presetStore.delete(id: ed.draft.id)
                    model.reloadPresets(selecting: Preset.factoryDefault.id, preserveContext: true)
                    model.savePresetSelection()   // não deixa o id excluído órfão na sessão
                    editor = nil
                }
            )
        }
    }

    // MARK: - Cartão (esquerda)

    private func cardPanel(_ model: AppModel, _ m: Metrics) -> some View {
        @Bindable var model = model
        let card = model.detectedCard
        return VStack(spacing: 0) {
            panelHeader(sourcePanelTitle(card))
            if model.sources.count > 1 {   // várias fontes conectadas → escolher qual
                Picker("", selection: Binding(get: { model.detectedCard?.url }, set: { model.selectedCardURL = $0 })) {
                    ForEach(model.sources) { s in Text(s.name).tag(URL?.some(s.url)) }
                }.labelsHidden().padding(.top, 6).disabled(model.isBusy)
            }
            Spacer(minLength: 3)
            Group {
                if let card, !card.isRemovable {
                    DriveIcon(size: m.icon)   // SSD/HD externo como fonte
                } else {
                    SDCardIcon(size: m.icon, present: card != nil)
                }
            }
                .background {
                    if card == nil {   // halo suave atrás do ícone pra a tela de espera não ficar seca
                        Circle()
                            .fill(RadialGradient(colors: [Color.accentColor.opacity(0.14), .clear],
                                                 center: .center, startRadius: 0, endRadius: m.icon * 0.95))
                            .frame(width: m.icon * 2.1, height: m.icon * 2.1)
                            .blur(radius: 6)
                    }
                }
            Spacer(minLength: 5)
            VStack(spacing: 10) {
                Text(card?.name ?? String(localized: "main.card.waiting"))
                    .font(.system(size: m.name, weight: .semibold)).multilineTextAlignment(.center).lineLimit(1)
                cardStats(model, hasCard: card != nil, gb: m.gb)
                if card == nil {
                    sourceDoor(model)
                }
            }
            Spacer(minLength: 6)
            cardControls(model, card: card)
        }
        .padding(18)
        .frame(width: m.cardW, height: m.cardH)
        .cardSurface()
    }

    @ViewBuilder
    private func cardControls(_ model: AppModel, card: ExternalVolume?) -> some View {
        @Bindable var model = model
        VStack(spacing: 8) {
            if model.activePreset.media.mode == .open {
                Picker("", selection: Binding(get: { model.mediaChoice },
                                              set: { model.mediaChoice = $0; model.savePresetSelection() })) {
                    Text("main.media.photo").tag(Preset.Media.Kind.photo)
                    Text("main.media.video").tag(Preset.Media.Kind.video)
                    Text("main.media.audio").tag(Preset.Media.Kind.audio)
                    Text("main.media.all").tag(Preset.Media.Kind.both)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.isBusy)
            }

            VStack(spacing: 7) {
                captureDateFilterControl(model)
                if let card {
                    sourceCorrectionButton(model, card: card)
                }
            }
        }
        .padding(.top, 2)
        .padding(.horizontal, 4)
    }

    /// Título do painel da fonte, adaptável ao que está conectado: vazio → FONTE, cartão → CARTÃO,
    /// disco externo (SSD/HD) → SSD.
    private func sourcePanelTitle(_ card: ExternalVolume?) -> LocalizedStringKey {
        guard let card else { return "main.panel.source" }
        return card.isRemovable ? "main.panel.card" : "main.panel.drive"
    }

    /// Porta de SSD: no estado de espera, deixa marcar um disco conectado como fonte (caso a câmera
    /// grave em SSD/HD e a detecção automática não pegue). Some quando não há disco pra escolher.
    @ViewBuilder
    private func sourceDoor(_ model: AppModel) -> some View {
        let disks = model.destinations.filter { !$0.isInternalShortcut }
        if !disks.isEmpty {
            VStack(spacing: 5) {
                Text("main.source.recordedElsewhere")
                    .font(.caption2).foregroundStyle(.secondary)
                Menu {
                    ForEach(disks) { disk in
                        Button(disk.name) { model.useAsSource(disk) }
                    }
                } label: {
                    Label("main.source.chooseAsSource", systemImage: "arrow.left.arrow.right")
                }
                .controlSize(.small)
                .fixedSize()
                .disabled(model.isBusy)
            }
            .padding(.top, 4)
        }
    }

    private func captureDateFilterControl(_ model: AppModel) -> some View {
        @Bindable var model = model
        let active = model.isCaptureDateFilterActive
        return Button {
            guard !model.isBusy else { return }
            syncCaptureFilterDrafts(from: model.captureDateFilter)
            showingCaptureFilter = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("main.captureFilter.controlTitle")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(active ? Color.primary.opacity(0.62) : Color.secondary)
                    Text(verbatim: model.captureDateFilterTitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.86))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(active ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.72))
            }
            .padding(.horizontal, 11)
            .frame(height: 42)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(active ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .disabled(model.isBusy)
        .accessibilityLabel(Text("main.captureFilter.a11yLabel"))
        .accessibilityValue(Text(verbatim: model.captureDateFilterTitle))
        .help("main.captureFilter.help")
        .popover(isPresented: $showingCaptureFilter, arrowEdge: .bottom) {
            captureDateFilterPopover(model)
        }
    }

    private func captureDateFilterPopover(_ model: AppModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("main.captureFilter.popoverTitle")
                    .font(.headline)
                Text("main.captureFilter.popoverSubtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("main.captureFilter.modeLabel",
                   selection: Binding(get: { filterDraftMode },
                                      set: {
                                          filterDraftMode = $0
                                          applyCaptureFilterDraftMode($0, to: model)
                                      })) {
                Text("main.captureFilter.modeAll").tag(CaptureDateFilterDraftMode.all)
                Text("main.captureFilter.modeToday").tag(CaptureDateFilterDraftMode.today)
                Text("main.captureFilter.modeOneDay").tag(CaptureDateFilterDraftMode.singleDay)
                Text("main.captureFilter.modeRange").tag(CaptureDateFilterDraftMode.range)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch filterDraftMode {
                case .all:
                    captureFilterSummary("main.captureFilter.summaryAll", systemImage: "tray.full")
                case .today:
                    captureFilterSummary("main.captureFilter.summaryToday", systemImage: "calendar.badge.clock")
                case .singleDay:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("main.captureFilter.chooseDay")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        CaptureDateStepper(
                            title: "main.captureFilter.day",
                            selection: Binding(get: { filterSingleDay },
                                               set: {
                                                   filterSingleDay = $0
                                                   model.setCaptureDateFilter(.singleDay($0))
                                               })
                        )
                    }
                case .range:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("main.captureFilter.chooseRange")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        CaptureDateStepper(
                            title: "main.captureFilter.startDate",
                            selection: Binding(get: { filterRangeStart },
                                               set: { setFilterRangeStart($0, model: model) }),
                            role: .start,
                            upperBound: filterRangeEnd
                        )
                        CaptureDateStepper(
                            title: "main.captureFilter.endDate",
                            selection: Binding(get: { filterRangeEnd },
                                               set: { setFilterRangeEnd($0, model: model) }),
                            lowerBound: filterRangeStart,
                            role: .end
                        )
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(16)
        .frame(width: 420)
    }

    private func captureFilterSummary(_ key: LocalizedStringKey, systemImage: String) -> some View {
        Label(key, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func syncCaptureFilterDrafts(from filter: AppModel.CaptureDateFilter) {
        let now = Date()
        switch filter {
        case .all:
            filterDraftMode = .all
            filterSingleDay = now
            filterRangeStart = now
            filterRangeEnd = now
        case .today(let anchor):
            filterDraftMode = .today
            filterSingleDay = anchor
            filterRangeStart = anchor
            filterRangeEnd = anchor
        case .singleDay(let anchor):
            filterDraftMode = .singleDay
            filterSingleDay = anchor
            filterRangeStart = anchor
            filterRangeEnd = anchor
        case .range(let start, let end):
            filterDraftMode = .range
            filterSingleDay = start
            filterRangeStart = start
            filterRangeEnd = end
        }
    }

    private func applyCaptureFilterDraftMode(_ mode: CaptureDateFilterDraftMode, to model: AppModel) {
        switch mode {
        case .all:
            model.setCaptureDateFilter(.all)
        case .today:
            let anchor = Date()
            filterSingleDay = anchor
            filterRangeStart = anchor
            filterRangeEnd = anchor
            model.setCaptureDateFilter(.today(anchor: anchor))
        case .singleDay:
            model.setCaptureDateFilter(.singleDay(filterSingleDay))
        case .range:
            model.setCaptureDateFilter(.range(start: filterRangeStart, end: filterRangeEnd))
        }
    }

    private func setFilterRangeStart(_ date: Date, model: AppModel) {
        filterRangeStart = date
        if Calendar.current.startOfDay(for: filterRangeEnd) < Calendar.current.startOfDay(for: date) {
            filterRangeEnd = date
        }
        model.setCaptureDateFilter(.range(start: filterRangeStart, end: filterRangeEnd))
    }

    private func setFilterRangeEnd(_ date: Date, model: AppModel) {
        let startDay = Calendar.current.startOfDay(for: filterRangeStart)
        let endDay = Calendar.current.startOfDay(for: date)
        filterRangeEnd = endDay < startDay ? filterRangeStart : date
        model.setCaptureDateFilter(.range(start: filterRangeStart, end: filterRangeEnd))
    }

    private func sourceCorrectionButton(_ model: AppModel, card: ExternalVolume) -> some View {
        Button { model.useAsDestination(card) } label: {
            Label("main.moveToDestination", systemImage: "arrow.right.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.caption.weight(.semibold))
        .disabled(model.isBusy)
        .help("main.moveToDestination.help")
        .frame(maxWidth: .infinity)
    }

    /// Estatísticas do cartão numa caixa interna (separa "o que é" de "quanto tem").
    @ViewBuilder
    private func cardStats(_ model: AppModel, hasCard: Bool, gb: CGFloat) -> some View {
        if let pv = model.cardPreview {
            VStack(spacing: 9) {
                let cols = statColumns(pv)
                if !cols.isEmpty {
                    HStack(spacing: 0) {
                        // só os tipos com contagem > 0 — selecionar Áudio não mostra mais "0 fotos / 0 vídeos".
                        ForEach(Array(cols.enumerated()), id: \.offset) { item in
                            if item.offset > 0 { Divider().frame(height: 28) }
                            statColumn(icon: item.element.icon, value: item.element.value, label: item.element.label)
                        }
                    }
                    Divider()
                }
                if model.showsRemainingHeadline {
                    Text("main.stat.remainingLabel")
                        .font(.caption2.weight(.semibold)).textCase(.uppercase)
                        .foregroundStyle(.secondary)
                }
                Text(humanBytes(model.headlineBytes))
                    .font(.system(size: gb, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                if model.showsRemainingHeadline {
                    // numa retomada o número grande é o que FALTA; aqui o total do cartão pra dar contexto.
                    Text(String(localized: "main.stat.ofTotal \(humanBytes(pv.totalBytes))"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                // a caixa de retomada (abaixo) detalha já copiados · novos · faltam.
                if let title = model.resumeCardTitle, let detail = model.resumeCardDetail {
                    VStack(spacing: 3) {
                        Label(title, systemImage: model.isComplementalCopy ? "plus.circle" : "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if let lote = pv.lote {
                    let loteState = String(localized: lote.isNovo ? "main.lote.new" : "main.lote.continues")
                    Label(String(localized: "main.lote.label \(String(format: "%02d", lote.numero)) \(loteState)"),
                          systemImage: "rectangle.stack")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if pv.junk > 0 {
                    Button {
                        ignoredFilesSheet = IgnoredFilesSheet(paths: pv.junkPaths)
                    } label: {
                        Label(String(localized: "main.junk.label \(pv.junk)"), systemImage: "list.bullet.rectangle")
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("main.junk.help")
                }
            }
            .padding(.vertical, 12).padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
        } else if hasCard {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("main.card.calculating").font(.callout).foregroundStyle(.secondary)
            }.frame(height: 96)
        } else {
            // Estado de espera: enriquece com os tipos de fonte aceitos — preenche o card (que de outro
            // jeito fica vazio) e reforça que cartão, SSD/HD e gravador funcionam. Some quando há disco
            // conectado (aí a porta "Escolher disco como fonte" já preenche e é o caminho de ação).
            let semDiscoConectado = model.destinations.filter { !$0.isInternalShortcut }.isEmpty
            VStack(spacing: 14) {
                Text("main.card.connectPrompt")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if semDiscoConectado {
                    VStack(alignment: .leading, spacing: 11) {
                        sourceTypeRow("sdcard.fill", "main.source.type.card")
                        sourceTypeRow("externaldrive.fill", "main.source.type.drive")
                        sourceTypeRow("waveform", "main.source.type.recorder")
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
                }
            }
        }
    }

    private func sourceTypeRow(_ icon: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).font(.callout)
                .foregroundStyle(Color.accentColor.opacity(0.85)).frame(width: 22)
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Colunas de tipo na prévia: só os tipos com contagem > 0 (ordem foto, vídeo, áudio, cinema).
    /// Selecionar só Áudio deixa de mostrar "0 fotos / 0 vídeos".
    private func statColumns(_ pv: OffloadPreview) -> [(icon: String, value: String, label: String)] {
        var cols: [(icon: String, value: String, label: String)] = []
        if pv.photos > 0 { cols.append((icon: "photo.fill", value: "\(pv.photos)", label: String(localized: "main.stat.photos"))) }
        if pv.videos > 0 { cols.append((icon: "video.fill", value: "\(pv.videos)", label: String(localized: "main.stat.videos"))) }
        if pv.audios > 0 { cols.append((icon: "waveform", value: "\(pv.audios)", label: String(localized: "main.stat.audios"))) }
        if pv.cinema > 0 { cols.append((icon: "film.fill", value: "\(pv.cinema)", label: String(localized: pv.cinema == 1 ? "main.stat.clip" : "main.stat.clips"))) }
        return cols
    }

    private func statColumn(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Destino (direita)

    private func destPanel(_ model: AppModel, _ m: Metrics) -> some View {
        @Bindable var model = model
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                panelHeader("main.panel.destination")

                // PRINCIPAL
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("main.dest.main")
                    diskPicker(selection: Binding(get: { model.destinationURL }, set: { model.setUserDestination($0) }),
                               disks: model.destinations, placeholder: String(localized: "main.dest.pickDisk"),
                               allowNone: false, disabled: model.isBusy)
                    if model.principalTooSmall {
                        Label("main.dest.noSpace", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    } else if let free = model.destinationFreeBytes, let total = model.destinationTotalBytes, total > 0 {
                        CapacityBar(free: free, total: total)
                    }
                    if model.internalPermissionDenied {
                        Label("main.dest.permissionDenied",
                              systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let inc = model.cardPreview?.lote?.anteriorIncompleto {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(String(localized: "main.lote.incomplete \(String(format: "%02d", inc))"),
                                  systemImage: "exclamationmark.octagon.fill")
                                .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                            Toggle("main.lote.acknowledgeNew",
                                   isOn: Binding(get: { model.acknowledgedIncompleteLote == inc },
                                                 set: { model.acknowledgedIncompleteLote = $0 ? inc : nil }))
                                .font(.caption).toggleStyle(.checkbox)
                        }
                    }
                    if let dest = model.destinations.first(where: { $0.url == model.destinationURL }) {
                        Button { model.useAsSource(dest) } label: {
                            Label("main.useAsSource", systemImage: "arrow.left.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.caption.weight(.semibold))
                        .disabled(model.isBusy)
                        .help("main.useAsSource.help")
                    }
                }

                // BACKUP (opcional)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("main.dest.backup")
                    diskPicker(selection: Binding(get: { model.backupURL }, set: { model.backupURL = $0; model.saveDiskSelection() }),
                               disks: model.destinations.filter { $0.url != model.destinationURL && !model.samePhysicalDisk($0.url, model.destinationURL) },
                               placeholder: String(localized: "main.dest.noneOption"), allowNone: true, disabled: model.isBusy)
                    if model.backupURL != nil {
                        if model.backupTooSmall {
                            Label("main.dest.noSpace", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        } else if let free = model.backupFreeBytes, let total = model.backupTotalBytes, total > 0 {
                            CapacityBar(free: free, total: total)
                        }
                        if model.backupNotConfirmed {
                            Label("main.dest.backupNotConfirmed", systemImage: "exclamationmark.triangle")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("main.dest.willCreate")
                    organizationChips(model)
                    Text("main.dest.previewExample")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { openEditor(.editing(model.activePreset)) } label: {
                        Label("main.dest.customize", systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain).disabled(model.isBusy)
                    .onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
                    if let backup = model.backupURL {
                        Text("main.dest.backupAt \(diskName(backup, model))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider().padding(.vertical, 2)

                    LabeledContent("main.dest.folder") {
                        TextField("main.dest.folderPlaceholder", text: $model.eventName).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity).disabled(model.isBusy)
                    }
                    if model.usesCameraToken {
                        LabeledContent("main.dest.camera") {
                            TextField("Cam01", text: $model.camera).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity).disabled(model.isBusy)
                        }
                    }
                    ForEach(Array(model.activePreset.sessionFields.enumerated()), id: \.offset) { _, f in
                        LabeledContent(f.label) {
                            TextField("", text: Binding(
                                get: { model.sessionValues[f.key] ?? "" },
                                set: { model.sessionValues[f.key] = $0 }
                            )).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity).disabled(model.isBusy)
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: m.cardW, height: m.cardH)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .cardSurface()
    }

    /// Seletor de disco reutilizável (principal e backup).
    private func diskPicker(selection: Binding<URL?>,
                            disks: [ExternalVolume], placeholder: String,
                            allowNone: Bool, disabled: Bool) -> some View {
        // Menu como BOTÃO bordered do sistema (borda nativa = sensação de clicável). Fica colado no
        // ícone à ESQUERDA com um Spacer empurrando o resto; largura mínima pra não ficar minúsculo.
        let currentName = disks.first { $0.url == selection.wrappedValue }?.name
        return HStack(spacing: 8) {
            DriveIcon(size: 18, lit: selection.wrappedValue != nil)
            Menu {
                if allowNone { Button(placeholder) { selection.wrappedValue = nil } }
                ForEach(disks.filter { !$0.isInternalShortcut }) { d in
                    Button(d.name) { selection.wrappedValue = d.url }
                }
                let internos = disks.filter { $0.isInternalShortcut }
                if !internos.isEmpty {
                    Section("main.dest.inComputer") {
                        ForEach(internos) { d in Button(d.name) { selection.wrappedValue = d.url } }
                    }
                }
            } label: {
                Text(currentName ?? placeholder)
                    .foregroundStyle(currentName == nil ? Color.secondary : Color.primary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(minWidth: 150, alignment: .leading)
            }
            .menuStyle(.button).buttonStyle(.bordered).controlSize(.large)
            .fixedSize().disabled(disabled)
            Spacer(minLength: 0)
        }
    }

    private func sectionLabel(_ s: LocalizedStringKey) -> some View {
        Text(s).font(.caption2.weight(.bold)).foregroundStyle(.secondary).tracking(0.4)
    }

    private func diskName(_ url: URL?, _ model: AppModel) -> String {
        model.destinations.first { $0.url == url }?.name ?? String(localized: "main.diskName.fallback")
    }

    // MARK: - Blocos do resultado (concluído)

    private func statTile(_ value: String, _ label: String, color: Color = .primary) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)   // tempos longos (2 h 15 min) encolhem sem estourar
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 7)   // largura IGUAL pros três (coerente)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func warningRow(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }

    private func skippedLine(_ o: OffloadOutcome) -> String {
        var parts: [String] = []
        if !o.skipped.isEmpty { parts.append(String(localized: "result.skipped \(o.skipped.count)")) }
        return parts.joined(separator: " · ")
    }

    private func resultTitle(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .frame(width: 18, height: 18)
            Text(text)
                .font(.callout.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(color)
    }

    private func resultInfoLine(_ title: String, detail: String? = nil, icon: String, color: Color = .secondary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .frame(width: 18, height: 18)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func ejectInline(ejected: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            resultInfoLine(String(localized: ejected ? "result.eject.done" : "result.eject.manual"),
                           detail: ejected ? String(localized: "result.eject.doneDetail")
                           : (model.ejectError != nil ? String(localized: "result.eject.inUse") : String(localized: "result.eject.beforeRemove")),
                           icon: ejected ? "eject.fill" : "eject",
                           color: ejected ? .green : .orange)
            if !ejected {
                Spacer(minLength: 0)
                Button("result.eject.retry") { model.retryEject() }
                    .controlSize(.small)
            }
        }
    }

    private func proofCompact(_ o: OffloadOutcome) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            resultTitle(String(localized: "result.proof.title"), icon: "checkmark.shield.fill", color: .green)
            resultInfoLine(proofLine(o), icon: "doc.text.magnifyingglass")
            if !o.manifestPaths.isEmpty {
                // mesma coluna de ícone (18pt) das outras linhas, pra alinhar; cor de link.
                Button { model.openReport(o) } label: {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.caption.weight(.semibold)).frame(width: 18, height: 18)
                        Text("result.proof.openReport").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
            }
        }
    }

    private func proofLine(_ o: OffloadOutcome) -> String {
        var parts = [String(localized: "result.proof.verifiedNow \(o.verifiedCount)")]
        if !o.skipped.isEmpty { parts.append(String(localized: "result.proof.alreadyPresent \(o.skipped.count)")) }
        if !o.manifestPaths.isEmpty { parts.append(String(localized: "result.proof.manifestSaved \(o.manifestPaths.count)")) }
        return parts.joined(separator: " · ")
    }

    private func finalResultTray(_ o: OffloadOutcome, saved: Bool, hasFailures: Bool, canFormat: Bool) -> some View {
        let readyCount = o.verifiedCount + o.skipped.count
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 11) {
                if hasFailures {
                    resultTitle(String(localized: "result.doNotFormat"), icon: "exclamationmark.octagon.fill", color: .red)
                } else if canFormat {
                    resultTitle(String(localized: "result.canFormat"), icon: "checkmark.seal.fill", color: .green)
                } else {
                    resultTitle(String(localized: "result.nothingToCopy"), icon: "questionmark.circle.fill", color: .orange)
                }

                if canFormat && (model.cardEjected || model.ejectError != nil) {
                    ejectInline(ejected: model.cardEjected)
                } else {
                    Text(canFormat ? "result.verifiedSafe" : "result.reviewBeforeAct")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                resultInfoLine(String(localized: "result.filesReady \(readyCount)"),
                               detail: String(localized: "result.atDestination"),
                               icon: "externaldrive.fill")
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Divider().frame(height: 112)

            VStack(alignment: .center, spacing: 11) {
                Text("result.nextStep")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    if canFormat {
                        Button { model.revealOffloadInFinder(o) } label: {
                            Label("result.openInFinder", systemImage: "folder")
                        }
                    }
                    Button("result.newCard") { model.reset() }
                }
                .controlSize(.regular)

                HStack(spacing: 8) {
                    if let e = model.lastElapsed { statTile(formatElapsed(e), String(localized: "result.stat.time")) }
                    statTile("\(o.verifiedCount)", String(localized: "result.stat.new"), color: saved && o.verifiedCount > 0 ? .green : .secondary)
                    statTile("\(o.failures.count)", String(localized: "result.stat.failures"), color: hasFailures ? .red : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Divider().frame(height: 112)

            VStack(alignment: .leading, spacing: 9) {
                if !o.unrecognized.isEmpty {
                    warningRow("questionmark.folder", String(localized: "result.warn.unrecognized \(o.unrecognized.count)"))
                }
                if !o.relocatedCinema.isEmpty {
                    warningRow("film.stack", String(localized: "result.warn.relocatedCinema \(o.relocatedCinema.count)"))
                }
                if !o.manifestFailures.isEmpty {
                    warningRow("doc.badge.ellipsis", String(localized: "result.warn.manifestFailures \(o.manifestFailures.joined(separator: ", "))"))
                }

                if canFormat {
                    proofCompact(o)
                }

                if !o.skipped.isEmpty {
                    resultInfoLine(skippedLine(o), icon: "arrow.clockwise")
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: 940)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder private var updateBannerArea: some View {
        if let version = updates.availableVersion { updateBanner(version) }
    }

    private func updateBanner(_ version: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
            Text("main.update.available \(version)").font(.callout.weight(.medium))
            Spacer()
            Button("main.update.install") { updates.install() }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Button { updates.availableVersion = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("main.update.dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func importPresetPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let cfp = UTType(filenameExtension: "cfp") {
            panel.allowedContentTypes = [cfp, .json]   // mostra só presets; .json como reserva
        }
        if panel.runModal() == .OK, let url = panel.url {
            do { try model.importPreset(from: url) } catch { importError = true }
        }
    }

    private func exportPresetPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PresetStore.exportFilename(for: model.activePreset)
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? model.exportActivePreset(to: url)
        }
    }

    private func panelHeader(_ title: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.caption.weight(.bold)).foregroundStyle(.primary.opacity(0.72)).tracking(0.5)
                Spacer()
            }
            Divider()
        }
    }

    // MARK: - Ação / resultado (baixo)

    private func bottomBar(_ model: AppModel) -> some View {
        Group {
            switch model.state {
            case .idle:
                if model.isAlreadyCopied {
                    alreadyCopiedReadyState(model)
                } else {
                    VStack(spacing: 10) {
                        Button(action: { model.startOffload() }) {
                            Label(model.isResume ? "main.action.resume" : "main.action.start",
                                  systemImage: model.isResume ? "arrow.clockwise" : "play.fill")
                                .font(.title3.bold()).frame(maxWidth: 360).padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .shadow(color: .accentColor.opacity(model.canStart ? 0.55 : 0), radius: 14, y: 0)
                        .disabled(!model.canStart)
                        if let hint = model.resumeActionHint {
                            Text(hint)
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                        }
                        if model.showsVerifiedResumeOption {
                            // opção avançada (reconferir o que já foi copiado): botão discreto, 1 elemento só
                            // (o detalhe "mais lento…" fica no tooltip, em vez de uma linha de ajuda separada).
                            Button { model.startOffload(fastResume: false) } label: {
                                Label("main.resume.verifyAll", systemImage: "checkmark.shield")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(!model.canStart)
                            .help(model.verifiedResumeHelpText)
                        }
                        if model.detectedCard != nil && model.destinationURL == nil {
                            // sem NENHUM destino conectado → mandar "escolher" um disco que não existe confunde.
                            Text(model.destinations.isEmpty
                                 ? "main.dest.noneConnected"
                                 : "main.dest.pickOne")
                                .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                        }
                    }
                }
            case .running(let p):
                VStack(spacing: 8) {
                    Label(model.isCancelling ? "main.running.stopping"
                          : (p.phase == .verifying ? "main.running.verifying"
                                                   : "main.copying"),
                          systemImage: model.isCancelling ? "stop.circle" : "lock.fill")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.isCancelling {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("main.running.stoppingShort").font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        Button(role: .destructive) { model.cancelOffload() } label: {
                            Label("main.running.stop", systemImage: "stop.fill")
                        }.controlSize(.regular)
                    }
                }
            case .finished(let o):
                let salvou = o.verifiedCount > 0 || !o.skipped.isEmpty   // p/ cor dos tiles (pode ser true mesmo com falha)
                let temFalha = !o.failures.isEmpty
                let podeFormatar = o.canSafelyFormatCard                  // decisão ÚNICA (igual à ejeção e ao badge)
                finalResultTray(o, saved: salvou, hasFailures: temFalha, canFormat: podeFormatar)
            case .failed(let msg, let cardUncertain):
                VStack(spacing: 8) {
                    if cardUncertain {
                        Label("result.doNotFormat", systemImage: "exclamationmark.octagon.fill")
                            .font(.headline).foregroundStyle(.red)
                        Text("main.failed.cardUncertain")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 440)
                    }
                    Text(verbatim: msg).font(.caption).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: 440)
                    Button("main.failed.back") { model.reset() }.controlSize(.large)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Segmentos da árvore que será criada no destino: o 1º é o DISCO (fixo); os demais vêm do MODELO
    /// de pastas (renderizados pelo motor real — datas viram "28 Mai 2026", caixa certa).
    private func pathSegments(_ model: AppModel) -> [String] {
        let dest = model.destinations.first(where: { $0.url == model.destinationURL })?.name ?? String(localized: "main.diskName.fallback")
        var p = model.activePreset
        p.evento = model.effectiveEvento
        guard case .success(let full) = NameBuilder(preset: p, locale: AppLocale.effective).preview(for: .previewSample, context: .previewContext) else {
            return [dest]
        }
        var folders = full.split(separator: "/").map(String.init)
        if !folders.isEmpty { folders.removeLast() }   // tira o nome do arquivo de exemplo, fica só a pasta
        // se a última pasta é o {tipo}, mostra os tipos que vão ser criados (conforme o filtro de mídia)
        if p.folderStructure.split(separator: "/").last.map(String.init) == "{tipo}", !folders.isEmpty {
            // mídia efetiva: preset travado usa lockedTo (igual ao refreshCardPreview); senão a escolha do usuário.
            let effective = p.media.mode == .locked ? p.media.lockedTo : model.mediaChoice
            folders[folders.count - 1] = tipoPreview(effective)
        }
        return [dest] + folders
    }

    /// A árvore do destino como chips: o 1º (o disco) é neutro/fixo; os demais (do modelo de pastas)
    /// ficam em destaque — comunica que a estrutura é configurável, não fixa do sistema.
    @ViewBuilder
    private func organizationChips(_ model: AppModel) -> some View {
        let segs = pathSegments(model)
        FlowRow(spacing: 4) {
            ForEach(Array(segs.enumerated()), id: \.offset) { i, seg in
                HStack(spacing: 4) {
                    Text(seg)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(i == 0 ? Color.secondary : Color.accentColor)
                        // nome de pasta longo não pode estourar a coluna (o destPanel corta sem reticência):
                        // 1 linha, reticência no meio, teto de largura que cabe na janela mínima.
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .leading)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(i == 0 ? Color.primary.opacity(0.08) : Color.accentColor.opacity(0.18),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    // chevron TRAILING: linha que quebra termina com "›" (continuação), a próxima começa limpa.
                    if i < segs.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func tipoPreview(_ kind: Preset.Media.Kind) -> String {
        switch kind {
        case .photo: return String(localized: "main.preview.tipo.photo")
        case .video: return String(localized: "main.preview.tipo.video")
        case .audio: return String(localized: "main.preview.tipo.audio")
        case .both: return String(localized: "main.preview.tipo.photoVideo")
        }
    }

    private func alreadyCopiedReadyState(_ model: AppModel) -> some View {
        VStack(spacing: 8) {
            Label(model.alreadyCopiedTitle ?? String(localized: "main.alreadyCopied.title"), systemImage: "checkmark.seal.fill")
                .font(.title3.bold())
                .foregroundStyle(.green)
            if let detail = model.alreadyCopiedDetail {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button { model.revealCurrentDestinationInFinder() } label: {
                Label("main.alreadyCopied.openDest", systemImage: "folder")
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 460)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.green.opacity(0.18), lineWidth: 1))
    }

    private func stateKey(_ state: AppModel.OffloadState) -> Int {
        switch state { case .idle: 0; case .running: 1; case .finished: 2; case .failed: 3 }
    }
}

// MARK: - Barra de capacidade do disco

private struct CapacityBar: View {
    let free: Int64
    let total: Int64
    var body: some View {
        let usedFrac = total > 0 ? max(0.0, min(1.0, Double(total - free) / Double(total))) : 0
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(usedFrac > 0.92 ? Color.orange : Color.accentColor)
                        .frame(width: max(4, geo.size.width * usedFrac))
                }
            }
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityLabel(Text("main.capacity.a11yLabel"))
            .accessibilityValue(Text("main.capacity.a11yValue \(humanBytes(free)) \(humanBytes(total)) \(String(Int((usedFrac * 100).rounded())))"))
            (Text("main.capacity.free").foregroundStyle(.secondary)
                + Text(verbatim: humanBytes(free)).fontWeight(.bold)
                + Text("main.capacity.of \(humanBytes(total))").foregroundStyle(.secondary))
                .font(.subheadline).monospacedDigit()
                .accessibilityHidden(true)   // a barra acima já anuncia o mesmo valor pro VoiceOver
        }
    }
}

private enum CaptureDateStepperRole {
    case start
    case end

    var marker: String {
        switch self {
        case .start: "1"
        case .end: "2"
        }
    }

    var color: Color {
        switch self {
        case .start: Color.accentColor
        case .end: Color.green
        }
    }
}

private struct CaptureDateStepper: View {
    let title: LocalizedStringKey
    @Binding private var selection: Date
    private let lowerBound: Date?
    private let upperBound: Date?
    private let role: CaptureDateStepperRole?

    init(title: LocalizedStringKey,
         selection: Binding<Date>,
         lowerBound: Date? = nil,
         role: CaptureDateStepperRole? = nil,
         upperBound: Date? = nil) {
        self.title = title
        _selection = selection
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.role = role
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                if let role {
                    Text(verbatim: role.marker)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(role.color, in: Circle())
                }
                Text(title)
                    .font(.caption.weight(role == nil ? .semibold : .bold))
                    .foregroundStyle(role?.color ?? Color.secondary)
            }

            HStack(spacing: 6) {
                stepButton("chevron.left.2", delta: .month(-1))
                stepButton("chevron.left", delta: .day(-1))

                Text(verbatim: selection.formatted(.dateTime.day().month().year()))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                stepButton("chevron.right", delta: .day(1))
                stepButton("chevron.right.2", delta: .month(1))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(stepperBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if let role {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(role.color.opacity(0.32), lineWidth: 1)
            }
        }
    }

    private enum StepDelta {
        case day(Int)
        case month(Int)
    }

    private func stepButton(_ systemImage: String, delta: StepDelta) -> some View {
        Button {
            move(delta)
        } label: {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .frame(width: 44, height: 40)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .disabled(!canMove(delta))
    }

    private var stepperBackground: Color {
        if let role {
            return role.color.opacity(0.09)
        }
        return Color.primary.opacity(0.055)
    }

    private func move(_ delta: StepDelta) {
        guard let next = date(after: delta), isWithinBounds(next) else { return }
        selection = next
    }

    private func canMove(_ delta: StepDelta) -> Bool {
        guard let next = date(after: delta) else { return false }
        return isWithinBounds(next)
    }

    private func date(after delta: StepDelta) -> Date? {
        switch delta {
        case .day(let value):
            return Calendar.current.date(byAdding: .day, value: value, to: selection)
        case .month(let value):
            return Calendar.current.date(byAdding: .month, value: value, to: selection)
        }
    }

    private func isWithinBounds(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        if let lowerBound, day < calendar.startOfDay(for: lowerBound) {
            return false
        }
        if let upperBound, day > calendar.startOfDay(for: upperBound) {
            return false
        }
        return true
    }
}

// MARK: - Fluxo de transferência (centro, com movimento)

private struct TransferFlow: View {
    let state: AppModel.OffloadState
    let canStart: Bool
    var arrow: CGFloat = 32
    var startedAt: Date? = nil   // pro cronômetro ao vivo durante a transferência

    var body: some View {
        VStack(spacing: 10) {
            switch state {
            case .idle:
                Image(systemName: "arrow.right")
                    .font(.system(size: arrow, weight: .bold))
                    .foregroundStyle(canStart ? Color.accentColor : Color.secondary)
                    .shadow(color: .accentColor.opacity(canStart ? 0.6 : 0), radius: 8)
            case .running(let p):
                MarchingChevrons()
                // barra por BYTES (não por arquivos): num clipe único de 18 GB a barra de arquivos
                // ficaria em 0/1 por minutos e pareceria travada — o que faz o leigo arrancar o cartão.
                ProgressView(value: Double(p.bytesDone), total: Double(max(p.bytesTotal, 1)))
                    .frame(width: 130).tint(.accentColor)
                // hierarquia: contagem grande (primário) > cronômetro + ETA (destaque) > bytes (detalhe)
                Group {
                    if p.phase == .scanning {
                        Text("main.flow.scanning")
                    } else if p.phase == .verifying {
                        Text("main.flow.verifyingShort")
                    } else {
                        Text(verbatim: "\(p.filesDone)/\(p.filesTotal)")
                    }
                }
                    .font(.title3.bold()).monospacedDigit().foregroundStyle(.primary)
                if let start = startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        let elapsed = ctx.date.timeIntervalSince(start)
                        VStack(spacing: 2) {
                            HStack(spacing: 5) {
                                Image(systemName: "clock").foregroundStyle(.tint).font(.caption)
                                Text(formatElapsed(elapsed))
                                    .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
                            }
                            if p.phase == .copying, p.bytesDone > 0, p.bytesTotal > p.bytesDone, elapsed > 1 {
                                let restante = Double(p.bytesTotal - p.bytesDone) / (Double(p.bytesDone) / elapsed)
                                Text("main.flow.remaining \(formatElapsed(restante))")
                                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
                Text(verbatim: "\(humanBytes(p.bytesDone)) / \(humanBytes(p.bytesTotal))")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            case .finished(let o):
                ResultBadge(ok: o.canSafelyFormatCard)
            case .failed:
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 42)).foregroundStyle(.red)
            }
        }
        .frame(minWidth: 110)
    }
}

private struct MarchingChevrons: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false
    var body: some View {
        Group {
            if reduceMotion {
                Image(systemName: "arrow.right")
            } else {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        Image(systemName: "chevron.right")
                            .opacity(animate ? 1 : 0.2)
                            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true).delay(Double(i) * 0.18), value: animate)
                    }
                }
            }
        }
        .font(.system(size: 22, weight: .bold))
        .foregroundStyle(Color.accentColor)
        .shadow(color: .accentColor.opacity(reduceMotion ? 0 : 0.6), radius: 8)
        .onAppear { if !reduceMotion { animate = true } }
    }
}

private struct ResultBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ok: Bool
    @State private var show = false
    var body: some View {
        VStack(spacing: 6) {
            badgeIcon
            Text(ok ? "main.badge.verified" : "main.badge.failed").font(.headline).foregroundStyle(ok ? .green : .red)
        }
        .onAppear { show = true }
    }

    @ViewBuilder private var badgeIcon: some View {
        let icon = Image(systemName: ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
            .font(.system(size: 48))
            .foregroundStyle(ok ? .green : .red)
            .shadow(color: (ok ? Color.green : Color.red).opacity(reduceMotion ? 0.2 : 0.5), radius: 10)
        if reduceMotion {
            icon
        } else {
            icon.symbolEffect(.bounce, value: show)
        }
    }
}

// MARK: - Superfície de card (fosco + profundidade)

private struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }
}
private extension View {
    func cardSurface() -> some View { modifier(CardSurface()) }
}

private struct IgnoredFilesSheet: Identifiable {
    let id = UUID()
    let paths: [String]
}

private struct IgnoredFilesView: View {
    let paths: [String]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("main.ignored.title", systemImage: "list.bullet.rectangle")
                        .font(.title3.weight(.semibold))
                    Text("main.ignored.detail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("main.ignored.close") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(paths, id: \.self) { path in
                        Text(verbatim: path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 240)
        }
        .padding(22)
        .frame(width: 560, height: 440)
    }
}

// finos invólucros pra OffloadKit.Format (fonte única, testada) — mantêm os call sites curtos.
func humanBytes(_ bytes: Int64) -> String { Format.humanBytes(bytes) }
func formatElapsed(_ seconds: TimeInterval) -> String { Format.elapsed(seconds) }
