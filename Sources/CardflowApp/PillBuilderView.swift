import SwiftUI
import AppKit
import OffloadKit
import UniformTypeIdentifiers

/// Construtor visual de um template (nome OU pastas) por peças, sem expor "{}".
/// Lê/escreve a fileira de segmentos via o PresetEditorModel; o modo define o separador padrão.
struct PillBuilderView: View {
    @Bindable var model: PresetEditorModel
    let row: PresetEditorModel.Row          // .folder ou .name
    let sessionFields: [Preset.SessionField]

    private var segments: [TemplateSegment] { row == .folder ? model.folderSegments : model.nameSegments }
    private var rowTag: String { row == .folder ? "folder" : "name" }

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, seg in
                segmentView(seg, index: index)
            }
            addMenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func segmentView(_ seg: TemplateSegment, index: Int) -> some View {
        Group {
            switch seg {
            case .literal(let text):
                SeparatorChip(text: text, folder: row == .folder) { model.setSeparator($0, at: index, in: row) }
            case .token(let name, let mods):
                TokenPill(name: name, modifiers: mods, sessionFields: sessionFields, model: model, index: index, row: row)
            }
        }
        .onDrag { NSItemProvider(object: "\(rowTag):\(index)" as NSString) }
        .onDrop(of: [.text], delegate: ReorderDrop(targetIndex: index, rowTag: rowTag, row: row, model: model))
    }

    private var addMenu: some View {
        Menu {
            ForEach(TokenCatalog.categoryOrder, id: \.self) { cat in
                let itens = TokenCatalog.all.filter { $0.category == cat && !escondido($0.name) }
                if !itens.isEmpty {
                    Section(cat) {
                        ForEach(itens, id: \.name) { info in
                            Button { model.addToken(info.name, to: row) } label: { Label(info.label, systemImage: info.systemImage) }
                        }
                    }
                }
            }
            if !sessionFields.isEmpty {
                Section("Campos personalizados") {
                    ForEach(sessionFields, id: \.key) { f in
                        Button { model.addToken(f.key, to: row) } label: { Label(f.label.isEmpty ? f.key : f.label, systemImage: "person.text.rectangle") }
                    }
                }
            }
        } label: {
            Image(systemName: "plus").frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // tokens granulares de data ficam escondidos atrás da pill "Data" (o popover dela troca o formato)
    private func escondido(_ name: String) -> Bool {
        ["ano", "ano2", "mes", "mes_abrev", "mes_nome", "dia", "horas", "minutos", "segundos", "hora"].contains(name)
    }
}

/// Pegador visual (2×3 pontinhos) que sinaliza "arrastável". Decorativo (acessibilidade ignora).
private struct GripDots: View {
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().frame(width: 2.5, height: 2.5)
                    }
                }
            }
        }
        .foregroundStyle(.secondary)
        .opacity(0.6)
        .accessibilityHidden(true)
    }
}

/// Uma peça-token: rótulo humano + ícone; toque abre popover (remover / caixa / formato/contador).
private struct TokenPill: View {
    let name: String
    let modifiers: [String]
    let sessionFields: [Preset.SessionField]
    @Bindable var model: PresetEditorModel
    let index: Int
    let row: PresetEditorModel.Row
    @State private var showOptions = false

    private var label: String {
        if let info = TokenCatalog.info(for: name) { return info.label }
        if let f = sessionFields.first(where: { $0.key == name }) { return f.label.isEmpty ? f.key : f.label }
        return name
    }
    private var systemImage: String { TokenCatalog.info(for: name)?.systemImage ?? "person.text.rectangle" }
    private var caseLabel: String { modifiers.contains("maiuscula") ? "AB" : (modifiers.contains("minuscula") ? "ab" : "") }

    var body: some View {
        Button { showOptions = true } label: {
            HStack(spacing: 4) {
                GripDots()
                Image(systemName: systemImage).font(.caption2)
                Text(label).font(.callout)
                if !caseLabel.isEmpty { Text(caseLabel).font(.caption2.bold()).foregroundStyle(.secondary) }
            }
            .padding(.leading, 6).padding(.trailing, 10).frame(height: 28)
            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            // set/unset (não push/pop): idempotente. Se o popover ou o drag engolir o onHover(false),
            // o set não corrompe a pilha global de cursor (push/pop vazaria e dava double-pop depois).
            if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
        }
        .popover(isPresented: $showOptions, arrowEdge: .bottom) { optionsPopover }
    }

    private var optionsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Caixa").font(.caption).foregroundStyle(.secondary)
                Picker("Caixa", selection: Binding(
                    get: { modifiers.contains("maiuscula") ? "maiuscula" : (modifiers.contains("minuscula") ? "minuscula" : "normal") },
                    set: { model.setCaseModifier($0 == "normal" ? nil : $0, at: index, in: row) }
                )) {
                    Text("Aa").tag("normal"); Text("AB").tag("maiuscula"); Text("ab").tag("minuscula")
                }.pickerStyle(.segmented).labelsHidden()
            }

            if name == "data" {
                Divider()
                Text("Formato da data").font(.caption).foregroundStyle(.secondary)
                ForEach(PresetEditorModel.dateFormatPresets, id: \.format) { preset in
                    Button { model.setDateFormat(preset.format) } label: {
                        HStack {
                            Image(systemName: model.draft.dateFormat == preset.format ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.draft.dateFormat == preset.format ? Color.accentColor : .secondary)
                            Text(preset.label).font(.callout.monospaced())
                            Spacer()
                        }
                    }.buttonStyle(.plain)
                }
            }
            if name == "contador" {
                Divider()
                Stepper("Dígitos: \(model.draft.rename.counterPadding)", value: $model.draft.rename.counterPadding, in: 1...8)
                Stepper("Começa em: \(model.draft.rename.counterStart)", value: $model.draft.rename.counterStart, in: 0...100_000)
                Stepper("Passo: \(model.draft.rename.counterStep)", value: $model.draft.rename.counterStep, in: 1...100)
            }
            Divider()
            Button(role: .destructive) { model.removeSegment(at: index, in: row); showOptions = false } label: {
                Label("Remover peça", systemImage: "trash")
            }.buttonStyle(.plain).foregroundStyle(.red)
        }
        .padding(14).frame(width: 280)
    }
}

/// Chip de separador (literal) entre peças. "/" só faz sentido nas PASTAS (no nome viraria subpasta).
private struct SeparatorChip: View {
    let text: String
    let folder: Bool
    let onChange: (String) -> Void
    private var opcoes: [String] { folder ? ["/", "_", "-", " "] : ["_", "-", " "] }
    var body: some View {
        Menu {
            ForEach(opcoes, id: \.self) { s in
                Button(s == " " ? "espaço" : s) { onChange(s) }
            }
        } label: {
            Text(text == " " ? "␣" : text).font(.callout.monospaced()).foregroundStyle(.secondary)
                .frame(width: 18, height: 28)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }
}

/// Drop delegate de reordenar: move só DENTRO da mesma fileira (rejeita arrastar pasta↔nome).
private struct ReorderDrop: DropDelegate {
    let targetIndex: Int
    let rowTag: String
    let row: PresetEditorModel.Row
    let model: PresetEditorModel
    func performDrop(info: DropInfo) -> Bool {
        guard let item = info.itemProviders(for: [.text]).first else { return false }
        item.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String else { return }
            let parts = s.components(separatedBy: ":")
            guard parts.count == 2, parts[0] == rowTag, let from = Int(parts[1]) else { return }  // só mesma fileira
            Task { @MainActor in model.moveSegment(from: from, to: targetIndex, in: row) }
        }
        return true
    }
}

/// Lista read-only de extensões reconhecidas — só informativo (não dá pra adicionar/remover).
struct TagListView: View {
    let tags: [String]
    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag).font(.callout)
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(Capsule().fill(.quaternary))
            }
            if tags.isEmpty { Text("nenhuma").font(.callout).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Layout que quebra linha (flow) e centraliza cada item verticalmente na sua linha (alinhamento limpo).
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var sizes: [CGSize] = []
        var lines: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified); sizes.append(s)
            if x > 0 && x + s.width > maxW { lines.append([]); x = 0 }
            lines[lines.count - 1].append(i); x += s.width + spacing
        }
        var y = bounds.minY
        for line in lines {
            let lineH = line.map { sizes[$0].height }.max() ?? 0
            var lx = bounds.minX
            for i in line {
                let s = sizes[i]
                subviews[i].place(at: CGPoint(x: lx, y: y + (lineH - s.height) / 2), proposal: .unspecified)
                lx += s.width + spacing
            }
            y += lineH + spacing
        }
    }
}
