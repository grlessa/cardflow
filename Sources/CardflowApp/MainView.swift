import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OffloadKit

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var editor: PresetEditorModel?
    @State private var confirmDelete = false
    @State private var importError = false

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
            cardH = min(max(size.height - 200, 360), 410)   // altura cresce pouco (form não estica)
            icon = 54 * s
            name = 22 * s
            gb = 25 * s
            arrow = 30 * s
            gap = 24 * s
        }
    }

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            let m = Metrics(geo.size)
            VStack(spacing: 14) {
                updateBannerArea
                // TOPO — preset
                HStack(spacing: 8) {
                    Text("Preset").font(.callout).foregroundStyle(.secondary)
                    Picker("", selection: $model.selectedPresetId) {
                        ForEach(model.presets, id: \.id) { p in Text(p.name).tag(p.id) }
                    }
                    .labelsHidden().fixedSize().disabled(model.isBusy)
                    Button { editor = .editing(model.activePreset) } label: {
                        Image(systemName: "pencil")
                    }
                    .help("Editar este preset").disabled(model.isBusy)
                    Button { editor = .creating() } label: {
                        Image(systemName: "plus")
                    }
                    .help("Novo preset").disabled(model.isBusy)
                    Menu {
                        Button("Importar preset…") { importPresetPanel() }
                        Button("Exportar este preset…") { exportPresetPanel() }
                        Button("Duplicar") { model.duplicateActivePreset() }
                        Divider()
                        Button("Excluir", role: .destructive) { confirmDelete = true }
                            .disabled(model.selectedPresetId == "factory-default")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuIndicator(.hidden).help("Gerenciar presets").disabled(model.isBusy)
                    .confirmationDialog("Excluir o preset “\(model.activePreset.name)”?",
                                        isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Excluir", role: .destructive) { model.deleteActivePreset() }
                        Button("Cancelar", role: .cancel) {}
                    }
                    .alert("Não consegui importar esse preset.", isPresented: $importError) {
                        Button("OK", role: .cancel) {}
                    }
                }
                .padding(.top, 16)

                // MEIO — cartão → fluxo → destino (cards crescem com a janela)
                HStack(alignment: .center, spacing: m.gap) {
                    cardPanel(model, m)
                    TransferFlow(state: model.state, canStart: model.canStart, arrow: m.arrow)
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
        .frame(minWidth: 760, minHeight: 560)
        .onChange(of: model.selectedPresetId) { model.presetSelectionChanged() }
        .onChange(of: model.watcher.volumes) { model.reconcileVolumes() }
        .onChange(of: model.detectedCard?.id) { model.refreshCardPreview() }
        .onChange(of: model.mediaChoice) { model.refreshCardPreview() }
        .onChange(of: model.destinationURL) { model.refreshCardPreview() }
        .onChange(of: model.backupURL) { model.refreshCardPreview() }
        .sheet(item: $editor) { ed in
            PresetEditorView(
                model: ed,
                onSave: {
                    if ed.save(into: model.presetStore) {
                        model.reloadPresets(selecting: ed.draft.id, preserveContext: true)
                        model.savePresetSelection()   // lembra o preset salvo/criado na sessão
                    }
                    editor = nil
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
            panelHeader("CARTÃO")
            if model.sources.count > 1 {   // várias fontes conectadas → escolher qual
                Picker("", selection: Binding(get: { model.detectedCard?.url }, set: { model.selectedCardURL = $0 })) {
                    ForEach(model.sources) { s in Text(s.name).tag(URL?.some(s.url)) }
                }.labelsHidden().padding(.top, 6).disabled(model.isBusy)
            }
            Spacer(minLength: 8)
            SDCardIcon(size: m.icon, present: card != nil)
            Spacer(minLength: 18)
            VStack(spacing: 12) {
                Text(card?.name ?? "Aguardando cartão")
                    .font(.system(size: m.name, weight: .semibold)).multilineTextAlignment(.center).lineLimit(1)
                cardStats(model, hasCard: card != nil, gb: m.gb)
            }
            Spacer(minLength: 16)
            if model.activePreset.media.mode == .open {
                Picker("", selection: Binding(get: { model.mediaChoice },
                                              set: { model.mediaChoice = $0; model.savePresetSelection() })) {
                    Text("Foto").tag(Preset.Media.Kind.photo)
                    Text("Vídeo").tag(Preset.Media.Kind.video)
                    Text("Áudio").tag(Preset.Media.Kind.audio)
                    Text("Tudo").tag(Preset.Media.Kind.both)
                }.pickerStyle(.segmented).labelsHidden().disabled(model.isBusy)
            }
            if let card {   // correção: se foi detectado errado, mover pra destino
                Button { model.useAsDestination(card) } label: {
                    Label("Não é a fonte? Mover pra destino", systemImage: "arrow.right.circle")
                }
                .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                .padding(.top, 8).disabled(model.isBusy)
            }
        }
        .padding(18)
        .frame(width: m.cardW, height: m.cardH)
        .cardSurface()
    }

    /// Estatísticas do cartão numa caixa interna (separa "o que é" de "quanto tem").
    @ViewBuilder
    private func cardStats(_ model: AppModel, hasCard: Bool, gb: CGFloat) -> some View {
        if let pv = model.cardPreview {
            VStack(spacing: 9) {
                HStack(spacing: 0) {
                    statColumn(icon: "photo.fill", value: "\(pv.photos)", label: "fotos")
                    Divider().frame(height: 28)
                    statColumn(icon: "video.fill", value: "\(pv.videos)", label: "vídeos")
                    if pv.audios > 0 {
                        Divider().frame(height: 28)
                        statColumn(icon: "waveform", value: "\(pv.audios)", label: "áudios")
                    }
                    if pv.cinema > 0 {
                        Divider().frame(height: 28)
                        statColumn(icon: "film.fill", value: "\(pv.cinema)", label: pv.cinema == 1 ? "clipe" : "clipes")
                    }
                }
                Divider()
                Text(humanBytes(pv.totalBytes))
                    .font(.system(size: gb, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                if pv.junk > 0 {
                    Text("\(pv.junk) ignorado(s) · thumbnail/lixo")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 12).padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
        } else if hasCard {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("calculando tamanho…").font(.callout).foregroundStyle(.secondary)
            }.frame(height: 96)
        } else {
            Text("conecte o cartão da câmera")
                .font(.callout).foregroundStyle(.secondary).frame(height: 96)
        }
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
            VStack(alignment: .leading, spacing: 10) {
                panelHeader("DESTINO")

                // PRINCIPAL
                sectionLabel("PRINCIPAL")
                diskPicker(selection: Binding(get: { model.destinationURL }, set: { model.setUserDestination($0) }),
                           disks: model.destinations, placeholder: "— escolha o disco —",
                           allowNone: false, disabled: model.isBusy)
                if model.principalTooSmall {
                    Label("sem espaço pro cartão", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else if let free = model.destinationFreeBytes, let total = model.destinationTotalBytes, total > 0 {
                    CapacityBar(free: free, total: total)
                }
                if let dest = model.destinations.first(where: { $0.url == model.destinationURL }) {
                    Button { model.useAsSource(dest) } label: {
                        Label("Usar como fonte", systemImage: "arrow.left.circle")
                    }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.isBusy)
                }

                // BACKUP (opcional)
                sectionLabel("BACKUP (OPCIONAL)")
                diskPicker(selection: Binding(get: { model.backupURL }, set: { model.backupURL = $0; model.saveDiskSelection() }),
                           disks: model.destinations.filter { $0.url != model.destinationURL && !model.samePhysicalDisk($0.url, model.destinationURL) },
                           placeholder: "— nenhum —", allowNone: true, disabled: model.isBusy)
                if model.backupURL != nil {
                    if model.backupTooSmall {
                        Label("sem espaço pro cartão", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    } else if let free = model.backupFreeBytes, let total = model.backupTotalBytes, total > 0 {
                        CapacityBar(free: free, total: total)
                    }
                    if model.backupNotConfirmed {
                        Label("não confirmei que é outro disco físico", systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }

                Divider().padding(.top, 2)
                sectionLabel("VAI CRIAR")
                Text(pathPreview(model)).font(.callout.monospaced())
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let backup = model.backupURL {
                    Text("+ backup em \(diskName(backup, model))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()

                LabeledContent("Pasta") {
                    TextField("nome da pasta", text: $model.eventName).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity).disabled(model.isBusy)
                }
                if model.usesCameraToken {
                    LabeledContent("Câmera") {
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
        // Menu como BOTÃO bordered do sistema: preenche a largura (igual aos campos) E desenha a
        // borda nativa (sensação de clicável), com o chevron do menu à direita. O Picker nativo e o
        // .borderlessButton centralizavam o conteúdo e deixavam o vão.
        let currentName = disks.first { $0.url == selection.wrappedValue }?.name
        return HStack(spacing: 8) {
            DriveIcon(size: 18, lit: selection.wrappedValue != nil)
            Menu {
                if allowNone { Button(placeholder) { selection.wrappedValue = nil } }
                ForEach(disks) { d in Button(d.name) { selection.wrappedValue = d.url } }
            } label: {
                Text(currentName ?? placeholder)
                    .foregroundStyle(currentName == nil ? Color.secondary : Color.primary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button).buttonStyle(.bordered).controlSize(.large)
            .frame(maxWidth: .infinity).disabled(disabled)
        }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.caption2.weight(.bold)).foregroundStyle(.tertiary).tracking(0.4)
    }

    private func diskName(_ url: URL?, _ model: AppModel) -> String {
        model.destinations.first { $0.url == url }?.name ?? "disco"
    }

    @ViewBuilder private var updateBannerArea: some View {
        if let up = model.availableUpdate { updateBanner(up) }
    }

    private func updateBanner(_ up: UpdateInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
            Text("Versão \(up.version) disponível").font(.callout.weight(.medium))
            Spacer()
            Button("Baixar") { NSWorkspace.shared.open(up.pageURL) }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Button { model.availableUpdate = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dispensar")
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
        panel.nameFieldStringValue = "\(model.activePreset.id).cfp"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? model.exportActivePreset(to: url)
        }
    }

    private func panelHeader(_ title: String) -> some View {
        HStack { Text(title).font(.caption.weight(.bold)).foregroundStyle(.secondary).tracking(0.5); Spacer() }
    }

    // MARK: - Ação / resultado (baixo)

    private func bottomBar(_ model: AppModel) -> some View {
        Group {
            switch model.state {
            case .idle:
                VStack(spacing: 6) {
                    Button(action: { model.startOffload() }) {
                        Label("INICIAR", systemImage: "play.fill")
                            .font(.title3.bold()).frame(maxWidth: 320).padding(.vertical, 9)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .shadow(color: .accentColor.opacity(model.canStart ? 0.55 : 0), radius: 14, y: 0)
                    .disabled(!model.canStart)
                    if model.detectedCard != nil && model.destinationURL == nil {
                        Text("Escolha um disco de destino").font(.caption).foregroundStyle(.orange)
                    }
                }
            case .running(let p):
                Label(p.phase == .verifying ? "Conferindo… não desconecte o cartão nem o disco"
                                            : "Copiando… não desconecte o cartão nem o disco",
                      systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.secondary)
            case .finished(let o):
                let salvou = o.verifiedCount > 0 || !o.skipped.isEmpty
                VStack(spacing: 8) {
                    if !o.failures.isEmpty {
                        Label("NÃO formate o cartão", systemImage: "exclamationmark.octagon.fill")
                            .font(.headline).foregroundStyle(.red)
                    } else if salvou {
                        Label("Pode formatar o cartão com segurança", systemImage: "checkmark.seal.fill")
                            .font(.headline).foregroundStyle(.green)
                    } else {
                        Label("Nada para copiar — confira o cartão ou o filtro de mídia", systemImage: "questionmark.circle.fill")
                            .font(.headline).foregroundStyle(.orange)
                    }
                    Text("Verificados \(o.verifiedCount) · Pulados \(o.skipped.count) · Falhas \(o.failures.count)"
                        + (o.unrecognized.isEmpty ? "" : " · \(o.unrecognized.count) não reconhecido(s)"))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if !o.relocatedCinema.isEmpty {
                        Label("\(o.relocatedCinema.count) clipe(s) de cinema movido(s) pra não sobrescrever filmagem diferente — confira o relink", systemImage: "film.stack")
                            .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                    }
                    if !o.manifestFailures.isEmpty {
                        Label("manifesto não salvo em \(o.manifestFailures.joined(separator: ", ")) — mídia ok, mas sem o registro", systemImage: "doc.badge.ellipsis")
                            .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                    }
                    if o.failures.isEmpty && salvou {
                        if model.cardEjected {
                            Label("Cartão ejetado — pode devolver e formatar", systemImage: "eject.fill")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if model.ejectError != nil {
                            Label("Ejete o cartão manualmente antes de remover", systemImage: "eject")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Button("Novo cartão") { model.reset() }.controlSize(.large)
                }
                .frame(maxWidth: .infinity)
            case .failed(let msg, let cardUncertain):
                VStack(spacing: 8) {
                    if cardUncertain {
                        Label("NÃO formate o cartão", systemImage: "exclamationmark.octagon.fill")
                            .font(.headline).foregroundStyle(.red)
                        Text("A cópia foi interrompida e a mídia não foi totalmente verificada. Mantenha o cartão como está e tente de novo.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 440)
                    }
                    Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: 440)
                    Button("Voltar") { model.reset() }.controlSize(.large)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func pathPreview(_ model: AppModel) -> String {
        var s = model.activePreset.folderStructure
        s = s.replacingOccurrences(of: "{evento}", with: model.effectiveEvento)
        s = s.replacingOccurrences(of: "{tipo}", with: "FOTO|VIDEO")
        let dest = model.destinations.first(where: { $0.url == model.destinationURL })?.name ?? "disco"
        return "\(dest) › \(s)"
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
            (Text("livre: ").foregroundStyle(.secondary)
                + Text(humanBytes(free)).fontWeight(.bold)
                + Text("  de \(humanBytes(total))").foregroundStyle(.secondary))
                .font(.subheadline).monospacedDigit()
        }
    }
}

// MARK: - Fluxo de transferência (centro, com movimento)

private struct TransferFlow: View {
    let state: AppModel.OffloadState
    let canStart: Bool
    var arrow: CGFloat = 32

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
                ProgressView(value: Double(p.filesDone), total: Double(max(p.filesTotal, 1)))
                    .frame(width: 130).tint(.accentColor)
                Text(p.phase == .scanning ? "Escaneando…"
                     : p.phase == .verifying ? "Conferindo…"
                     : "\(p.filesDone)/\(p.filesTotal)")
                    .font(.caption.bold()).monospacedDigit().foregroundStyle(.primary)
                Text("\(humanBytes(p.bytesDone)) / \(humanBytes(p.bytesTotal))")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            case .finished(let o):
                ResultBadge(ok: o.failures.isEmpty && (o.verifiedCount > 0 || !o.skipped.isEmpty))
            case .failed:
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 42)).foregroundStyle(.red)
            }
        }
        .frame(minWidth: 110)
    }
}

private struct MarchingChevrons: View {
    @State private var animate = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: "chevron.right")
                    .opacity(animate ? 1 : 0.2)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true).delay(Double(i) * 0.18), value: animate)
            }
        }
        .font(.system(size: 22, weight: .bold))
        .foregroundStyle(Color.accentColor)
        .shadow(color: .accentColor.opacity(0.6), radius: 8)
        .onAppear { animate = true }
    }
}

private struct ResultBadge: View {
    let ok: Bool
    @State private var show = false
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .font(.system(size: 48))
                .foregroundStyle(ok ? .green : .red)
                .symbolEffect(.bounce, value: show)
                .shadow(color: (ok ? Color.green : Color.red).opacity(0.5), radius: 10)
            Text(ok ? "Verificado" : "Falhou").font(.headline).foregroundStyle(ok ? .green : .red)
        }
        .onAppear { show = true }
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

func humanBytes(_ bytes: Int64) -> String {
    // decimal (1000), igual ao Finder e ao Ajustes do macOS — pra o número bater com o que o
    // usuário vê no disco. O binário (1024) mostrava 70.8 onde o Finder mostra 76.0 (mesma mídia).
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(bytes); var i = 0
    while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
    return String(format: i == 0 ? "%.0f %@" : "%.1f %@", v, units[i])
}
