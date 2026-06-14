import SwiftUI
import AppKit
import OffloadKit
import UniformTypeIdentifiers

/// Construtor de PASTAS em níveis: cada linha é uma pasta (a de baixo fica DENTRO da de cima).
/// Tira o "/" da cabeça do usuário — pasta é linha, texto/peça é conteúdo da linha.
struct FolderLevelsBuilder: View {
    @Bindable var model: PresetEditorModel
    let sessionFields: [Preset.SessionField]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(model.folderLevels.enumerated()), id: \.offset) { i, _ in
                HStack(alignment: .center, spacing: 7) {
                    if i > 0 {   // conector em L (└─), estilo árvore de pastas — desce e entra na de baixo
                        TreeBranch().padding(.leading, CGFloat(i - 1) * 22 + 4)
                    }
                    Image(systemName: "folder.fill").foregroundStyle(.secondary).font(.callout)
                    PillBuilderView(model: model, lane: .folder(i), sessionFields: sessionFields)
                    if model.folderLevels.count > 1 {
                        Button { model.removeFolderLevel(i) } label: {
                            Image(systemName: "minus.circle").font(.body).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain).help("pill.folder.remove.help")
                        .onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
                    }
                }
            }
            Divider().padding(.top, 4)   // separa a estrutura do botão de adicionar
            HStack(spacing: 0) {
                Spacer(minLength: 0)   // "nova pasta" fixo no canto direito
                Button { model.addFolderLevel() } label: {
                    Label("pill.folder.add", systemImage: "plus")
                        .font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.45),
                                                        style: StrokeStyle(lineWidth: 1.2, dash: [5, 3])))
                }
                .buttonStyle(.plain)
                .onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Construtor visual de UMA lane (o nome do arquivo, ou um nível de pasta) por peças, sem expor "{}".
struct PillBuilderView: View {
    @Bindable var model: PresetEditorModel
    let lane: PresetEditorModel.Lane
    let sessionFields: [Preset.SessionField]

    private var segments: [TemplateSegment] {
        switch lane { case .name: return model.nameSegments
        case .folder(let i): return model.folderLevels.indices.contains(i) ? model.folderLevels[i] : [] }
    }
    private var laneTag: String {
        switch lane { case .name: return "name"; case .folder(let i): return "folder-\(i)" }
    }

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
                if TemplateTokenizer.separators.contains(text) {
                    SeparatorChip(text: text) { model.setSeparator($0, at: index, in: lane) }
                } else {   // texto livre digitado pelo usuário (ex.: "Culto")
                    TextPill(text: text, model: model, index: index, lane: lane)
                }
            case .token(let name, let mods):
                TokenPill(name: name, modifiers: mods, sessionFields: sessionFields, model: model, index: index, lane: lane)
            }
        }
        .onDrag { NSItemProvider(object: "\(laneTag):\(index)" as NSString) }
        .onDrop(of: [.text], delegate: ReorderDrop(targetIndex: index, laneTag: laneTag, lane: lane, model: model))
    }

    private var addMenu: some View {
        Menu {
            Button { model.addText(to: lane) } label: { Label("pill.add.text", systemImage: "character.cursor.ibeam") }
            Divider()
            ForEach(TokenCatalog.categoryOrder, id: \.self) { cat in
                let itens = TokenCatalog.all.filter { $0.category == cat }
                if !itens.isEmpty {
                    Section(LocalizedStringKey(cat)) {
                        ForEach(itens, id: \.name) { info in
                            Button { model.addToken(info.name, to: lane) } label: { Label(LocalizedStringKey(info.label), systemImage: info.systemImage) }
                        }
                    }
                }
            }
            if !sessionFields.isEmpty {
                Section("pill.section.customFields") {
                    ForEach(sessionFields, id: \.key) { f in
                        Button { model.addToken(f.key, to: lane) } label: { Label(f.label.isEmpty ? f.key : f.label, systemImage: "person.text.rectangle") }
                    }
                }
            }
        } label: {
            Image(systemName: "plus").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
    }
}

/// Conector em L (└─) entre pastas, estilo árvore de arquivos: linha vem de cima e entra na pasta.
private struct TreeBranch: View {
    var body: some View {
        Path { p in
            let midY: CGFloat = 14
            p.move(to: CGPoint(x: 5, y: -3))         // vem de cima (da pasta anterior)
            p.addLine(to: CGPoint(x: 5, y: midY))    // desce
            p.addLine(to: CGPoint(x: 15, y: midY))   // entra (horizontal)
        }
        .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        .frame(width: 16, height: 28)
        .accessibilityHidden(true)
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

/// Peça de TEXTO LIVRE editável (ex.: "Culto"). Cinza, pra se distinguir das peças-token (azuis).
/// Binding DIRETO ao modelo (sem @State) pra não dessincronizar quando peças são movidas/removidas.
private struct TextPill: View {
    let text: String
    @Bindable var model: PresetEditorModel
    let index: Int
    let lane: PresetEditorModel.Lane

    var body: some View {
        HStack(spacing: 3) {
            TextField("pill.text.placeholder", text: Binding(
                get: { text },
                set: { model.setText($0, at: index, in: lane) }))
                .textFieldStyle(.plain).font(.callout).frame(minWidth: 36).fixedSize()
            Button { model.removeSegment(at: index, in: lane) } label: {
                Image(systemName: "xmark.circle.fill").font(.caption2)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("pill.text.remove.help")
        }
        .padding(.leading, 9).padding(.trailing, 5).frame(height: 28)
        .background(Capsule().fill(.quaternary))
        .overlay(Capsule().strokeBorder(.secondary.opacity(0.3), lineWidth: 1))
    }
}

/// Uma peça-token: rótulo humano + ícone; toque abre popover (remover / caixa / formato/contador).
private struct TokenPill: View {
    let name: String
    let modifiers: [String]
    let sessionFields: [Preset.SessionField]
    @Bindable var model: PresetEditorModel
    let index: Int
    let lane: PresetEditorModel.Lane
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
                Text(LocalizedStringKey(label)).font(.callout)
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
                Text("pill.case.label").font(.caption).foregroundStyle(.secondary)
                Picker("pill.case.label", selection: Binding(
                    get: { modifiers.contains("maiuscula") ? "maiuscula" : (modifiers.contains("minuscula") ? "minuscula" : "normal") },
                    set: { model.setCaseModifier($0 == "normal" ? nil : $0, at: index, in: lane) }
                )) {
                    Text("Aa").tag("normal"); Text("AB").tag("maiuscula"); Text("ab").tag("minuscula")
                }.pickerStyle(.segmented).labelsHidden()
            }

            if name == "data" {
                Divider()
                Text("pill.dateFormat.label").font(.caption).foregroundStyle(.secondary)
                ForEach(PresetEditorModel.dateFormatPresets, id: \.format) { preset in
                    Button { model.setDateFormat(preset.format) } label: {
                        HStack {
                            Image(systemName: model.draft.dateFormat == preset.format ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.draft.dateFormat == preset.format ? Color.accentColor : .secondary)
                            Text(preset.label).font(.callout)
                            Spacer()
                        }
                    }.buttonStyle(.plain)
                }
            }
            if name == "hora" {
                Divider()
                Text("pill.timeFormat.label").font(.caption).foregroundStyle(.secondary)
                ForEach(PresetEditorModel.timeFormatPresets, id: \.format) { preset in
                    Button { model.setTimeFormat(preset.format) } label: {
                        HStack {
                            Image(systemName: model.draft.timeFormat == preset.format ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.draft.timeFormat == preset.format ? Color.accentColor : .secondary)
                            Text(preset.label).font(.callout)
                            Spacer()
                        }
                    }.buttonStyle(.plain)
                }
            }
            if name == "contador" {
                Divider()
                Stepper("pill.counter.digits \(model.draft.rename.counterPadding)", value: $model.draft.rename.counterPadding, in: 1...8)
                Stepper("pill.counter.start \(model.draft.rename.counterStart)", value: $model.draft.rename.counterStart, in: 0...100_000)
                Stepper("pill.counter.step \(model.draft.rename.counterStep)", value: $model.draft.rename.counterStep, in: 1...100)
            }
            Divider()
            Button(role: .destructive) { model.removeSegment(at: index, in: lane); showOptions = false } label: {
                Label("pill.segment.remove", systemImage: "trash")
            }.buttonStyle(.plain).foregroundStyle(.red)
        }
        .padding(14).frame(width: 280)
    }
}

/// Juntador (separador) entre peças DENTRO de um nome/nível: une com espaço, "-" ou "_".
/// Pequeno chip com fundo, pra ler como controle clicável (não como texto solto). Espaço vira "·".
private struct SeparatorChip: View {
    let text: String
    let onChange: (String) -> Void
    var body: some View {
        Menu {
            Button("pill.separator.space") { onChange(" ") }
            Button("pill.separator.hyphen") { onChange("-") }
            Button("pill.separator.underline") { onChange("_") }
        } label: {
            Text(text == " " ? "·" : text)
                .font(.callout.weight(.bold).monospaced()).foregroundStyle(.secondary)
                .frame(width: 20, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.8)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("pill.separator.help")
        .onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
    }
}

/// Drop delegate de reordenar: move só DENTRO da mesma lane (rejeita arrastar entre pastas/nome).
private struct ReorderDrop: DropDelegate {
    let targetIndex: Int
    let laneTag: String
    let lane: PresetEditorModel.Lane
    let model: PresetEditorModel
    func performDrop(info: DropInfo) -> Bool {
        guard let item = info.itemProviders(for: [.text]).first else { return false }
        item.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String else { return }
            let parts = s.components(separatedBy: ":")
            guard parts.count == 2, parts[0] == laneTag, let from = Int(parts[1]) else { return }  // só mesma lane
            Task { @MainActor in model.moveSegment(from: from, to: targetIndex, in: lane) }
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
            if tags.isEmpty { Text("pill.tags.none").font(.callout).foregroundStyle(.tertiary) }
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
