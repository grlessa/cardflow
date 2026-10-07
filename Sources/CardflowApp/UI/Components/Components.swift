import SwiftUI
import OffloadKit

/// Espaço livre e total do volume de um caminho (mesma regra do motor: exFAT zera a chave
/// "importantUsage", então cai pra disponível genérica).
struct DiskSpace: Equatable {
    let free: Int64
    let total: Int64
    var usedFraction: Double { total > 0 ? max(0, min(1, Double(total - free) / Double(total))) : 0 }

    init?(url: URL) {
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                        .volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
              let total = v.volumeTotalCapacity, total > 0
        else { return nil }
        self.free = VolumeFreeSpace.choose(important: v.volumeAvailableCapacityForImportantUsage,
                                           generic: v.volumeAvailableCapacity.map(Int64.init))
        self.total = Int64(total)
    }
}

/// Barra fina de ocupação do disco, com o texto "x livres de y" opcional.
struct CapacityLine: View {
    let space: DiskSpace
    var showsText = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(space.usedFraction > 0.92 ? Color.orange : Color.accentColor)
                        .frame(width: max(3, g.size.width * space.usedFraction))
                }
            }
            .frame(height: 4)
            if showsText {
                Text("capacity.freeOf \(Format.bytes(space.free)) \(Format.bytes(space.total))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("main.capacity.a11yLabel"))
        .accessibilityValue(Text("capacity.freeOf \(Format.bytes(space.free)) \(Format.bytes(space.total))"))
    }
}

extension Format {
    /// Bytes no formato do sistema (vírgula decimal em pt-BR).
    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}

/// Lista dos itens que o Cardflow ignora (miniaturas, lixo do sistema), pra conferência.
struct IgnoredFilesView: View {
    let paths: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(paths, id: \.self) { path in
                Text(verbatim: path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            .navigationTitle(Text("main.ignored.title"))
            .navigationSubtitle(Text("main.ignored.detail"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("main.ignored.close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

// MARK: - Filtro de data de captura

/// Botão compacto + popover pra escolher quais dias do cartão copiar (todos, hoje, um dia, intervalo).
struct CaptureDateFilterButton: View {
    @Environment(AppModel.self) private var model
    let card: CardSession
    @State private var showing = false
    @State private var mode: Mode = .all
    @State private var single = Date()
    @State private var start = Date()
    @State private var end = Date()

    enum Mode: Hashable { case all, today, singleDay, range }

    var body: some View {
        let active = card.captureDateFilter != .all
        Button {
            sync()
            showing = true
        } label: {
            Label(AppModel.captureDateFilterTitle(card.captureDateFilter),
                  systemImage: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .tint(active ? .accentColor : nil)
        .spacedLabels()
        .disabled(card.isBusy)
        .help("main.captureFilter.help")
        .popover(isPresented: $showing, arrowEdge: .bottom) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("main.captureFilter.popoverTitle").font(.headline)
            Text("main.captureFilter.popoverSubtitle")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("main.captureFilter.modeLabel", selection: Binding(get: { mode }, set: { mode = $0; apply() })) {
                Text("main.captureFilter.modeAll").tag(Mode.all)
                Text("main.captureFilter.modeToday").tag(Mode.today)
                Text("main.captureFilter.modeOneDay").tag(Mode.singleDay)
                Text("main.captureFilter.modeRange").tag(Mode.range)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch mode {
            case .all:
                Label("main.captureFilter.summaryAll", systemImage: "tray.full").foregroundStyle(.secondary)
            case .today:
                Label("main.captureFilter.summaryToday", systemImage: "calendar.badge.clock").foregroundStyle(.secondary)
            case .singleDay:
                DatePicker("main.captureFilter.day", selection: Binding(get: { single }, set: { single = $0; apply() }),
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
            case .range:
                Form {
                    DatePicker("main.captureFilter.startDate", selection: Binding(get: { start }, set: {
                        start = $0; if end < start { end = start }; apply()
                    }), displayedComponents: .date)
                    DatePicker("main.captureFilter.endDate", selection: Binding(get: { end }, set: {
                        end = max($0, start); apply()
                    }), in: start..., displayedComponents: .date)
                }
                .formStyle(.columns)
            }
        }
        .padding(18)
        .frame(width: 380)
        .spacedLabels()
    }

    private func sync() {
        switch card.captureDateFilter {
        case .all: mode = .all
        case .today(let a): mode = .today; single = a; start = a; end = a
        case .singleDay(let d): mode = .singleDay; single = d; start = d; end = d
        case .range(let s, let e): mode = .range; start = s; end = e; single = s
        }
    }

    private func apply() {
        let f: AppModel.CaptureDateFilter
        switch mode {
        case .all: f = .all
        case .today: f = .today(anchor: Date())
        case .singleDay: f = .singleDay(single)
        case .range: f = .range(start: start, end: end)
        }
        model.setCaptureDateFilter(f, for: card)
    }
}

// MARK: - Seções do detalhe

/// Rolagem do detalhe com largura de leitura. Substitui o `Form` agrupado: no Mac ele é uma tabela do
/// AppKit, e com a coluna estreita (painel do modelo aberto) a medição das linhas entrava em laço.
struct DetailScroll<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .labeledContentStyle(SpreadLabeledContentStyle())
                .spacedLabels()
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Seção agrupada: título, linhas numa caixa arredondada com divisórias, nota opcional.
struct DetailSection<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey?
    let footer: LocalizedStringKey?
    let accessory: Accessory
    let content: Content

    init(_ title: LocalizedStringKey? = nil, footer: LocalizedStringKey? = nil,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title; self.footer = footer; self.accessory = accessory(); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Spacer(minLength: 8)
                    accessory
                }
                .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        row
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        if row.id != rows.last?.id { Divider().padding(.leading, 14) }
                    }
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
            if let footer {
                Text(footer).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Rótulo à esquerda (com subtítulo opcional) e controle à direita, como nos Ajustes do Sistema.
struct SpreadLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) { configuration.label }
                .layoutPriority(1)
            Spacer(minLength: 8)
            configuration.content
        }
    }
}

/// Ícone e texto com respiro. O `Label` padrão do Mac cola os dois (≈4 pt); aqui fica 7 pt, centrado.
struct SpacedLabelStyle: LabelStyle {
    var spacing: CGFloat = 7
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

extension View {
    /// Rótulos com ícone e texto espaçados em toda a área (detalhe, painel, lateral, folhas, balões).
    func spacedLabels() -> some View { labelStyle(SpacedLabelStyle()) }
}

/// Campo de texto que guarda o que se digita e só passa pro app quando a pessoa para de digitar, dá Return
/// ou sai do campo. Pra campos cuja mudança recalcula prévias: a cada tecla o recálculo devolvia um valor
/// velho pro campo e letras se perdiam (ou o cursor pulava pro começo).
struct DeferredTextField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var delay: Duration = .milliseconds(400)
    @State private var local = ""
    @State private var pending: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(_ title: LocalizedStringKey, text: Binding<String>, delay: Duration = .milliseconds(400)) {
        self.title = title; self._text = text; self.delay = delay
    }

    var body: some View {
        TextField(title, text: $local)
            .focused($focused)
            .onSubmit { commit() }
            .onAppear { local = text }
            // mudança de fora (modelo trocado, desfazer): só quando a pessoa não está digitando
            .onChange(of: text) { if !focused && local != text { local = text } }
            .onChange(of: local) {
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: delay)
                    if !Task.isCancelled { commit() }
                }
            }
            .onChange(of: focused) { if !focused { commit() } }
            .onDisappear { commit() }
    }

    private func commit() {
        pending?.cancel()
        if text != local { text = local }
    }
}
