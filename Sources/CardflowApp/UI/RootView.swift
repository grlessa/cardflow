import SwiftUI
import OffloadKit

/// Janela principal: barra lateral (cartões, destinos, recentes) + detalhe + painel do modelo à direita.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("cardflow.didOnboard") private var didOnboard = false
    /// Janela estreita: o campo Projeto encolhe (muda só ao redimensionar, nunca enquanto se digita).
    @State private var narrow = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .stableColumn()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            DetailRouter()
                .stableColumn()
        }
        .inspector(isPresented: Binding(get: { model.inspectorShown }, set: { model.setInspector($0) })) {
            ModelInspector()
                .stableColumn()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
        .frame(minWidth: 720, minHeight: 520)
        // painel aberto numa janela estreita demais pra lateral + detalhe + painel: ele fecha sozinho (como
        // no Xcode). Apertadas, as colunas do NSSplitView entravam em laço e o AppKit derrubava o app.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if width < AppModel.inspectorMinWindowWidth - 40 && model.inspectorShown { model.inspectorShown = false }
            if (width < 900) != narrow { narrow = width < 900 }
        }
        .toolbar { MainToolbar(inspectorShown: Binding(get: { model.inspectorShown }, set: { model.setInspector($0) }), narrow: narrow) }
        .toolbar(removing: .title)
        .sheet(isPresented: $model.showOnboarding) { OnboardingSheet() }
        .sheet(isPresented: $model.showManageModels) { ManageModelsSheet() }
        .sheet(item: Binding(get: { model.cardAwaitingFormatConfirmation }, set: { if $0 == nil { model.cancelAllFormatConfirmations() } })) { card in
            FormatConfirmSheet(card: card)
        }
        .alert("main.importError", isPresented: Binding(get: { model.modelError != nil }, set: { if !$0 { model.modelError = nil } })) {
            Button("main.ok", role: .cancel) { model.modelError = nil }
        }
        .onChange(of: model.watcher.volumes) { model.reconcileVolumes() }
        .onChange(of: model.selectedPresetId) { model.presetSelectionChanged() }
        .onChange(of: model.projectName) { model.recomputeAllPreviews() }
        .onChange(of: model.sessionValues) { model.recomputeAllPreviews() }
        .onAppear {
            if !didOnboard { didOnboard = true; model.showOnboarding = true }
        }
    }
}

extension View {
    /// Coluna do split view com tamanho mínimo zero. Sem isso, o mínimo que o conteúdo informa muda
    /// conforme a largura (texto que quebra linha, barra de ação) e o NSSplitView reajusta as colunas em
    /// laço até o AppKit derrubar o app (aconteceu ao abrir o painel do modelo).
    func stableColumn() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

/// Barra de ferramentas: projeto no centro; modelo, copiar todos e painel do modelo à direita.
struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Binding var inspectorShown: Bool
    var narrow = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) { ProjectField(width: narrow ? 150 : 200) }
        ToolbarItem(placement: .primaryAction) { ModelPicker() }
        ToolbarItem(placement: .primaryAction) {
            Button { model.enqueueAll() } label: {
                Label("toolbar.copyAll", systemImage: "square.and.arrow.down.on.square")
            }
            .help("toolbar.copyAll.help")
            .disabled(model.readyToCopyCount < 2)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { inspectorShown.toggle() } label: {
                Label("toolbar.model", systemImage: "sidebar.trailing")
            }
            .help("toolbar.model.help")
        }
    }
}

/// Campo do nome do projeto (a pasta principal no destino).
struct ProjectField: View {
    @Environment(AppModel.self) private var model
    /// Largura FIXA: largura flexível fazia a barra remedir o item a cada letra e recriar o campo, e o
    /// cursor voltava pro começo ("XY" virava "YX").
    var width: CGFloat = 200

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 7) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // texto próprio, passado pro app na pausa: cada nome recalcula a prévia de todos os cartões
            DeferredTextField("toolbar.project.placeholder", text: $model.projectName)
                .textFieldStyle(.plain)
                .frame(width: width)
                .disabled(model.cards.contains { $0.isBusy })
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .help("toolbar.project.help")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("toolbar.project.label"))
    }
}

extension AppModel {
    /// Cartão com a confirmação de formatar aberta (a do automático não pergunta de novo).
    var cardAwaitingFormatConfirmation: CardSession? {
        cards.first { if case .confirming = $0.formatState { return !$0.confirmingAutomatically }; return false }
    }
    func cancelAllFormatConfirmations() {
        for c in cards { cancelFormatConfirmation(c) }
    }
}
