import SwiftUI
import OffloadKit

/// Editor de uma pasta do modelo. Primeiro os formatos prontos, cada um com o nome real que a pasta vai
/// ter; quem precisa de outro monta em "Personalizar", como uma frase (peças e texto, com o que vai entre
/// elas). Tudo muda a prévia na hora.
struct FolderLevelEditor: View {
    @Bindable var editor: PresetEditorModel
    let index: Int
    let example: String
    /// Nome que um conjunto de peças daria a esta pasta, com o arquivo e o projeto de agora.
    let render: ([TemplateSegment]) -> String
    let onRemove: () -> Void
    @State private var customizing = false

    private var current: [TemplateSegment] { editor.folderLevels[safe: index] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    group("folder.formats.date", FolderFormats.date)
                    group("folder.formats.other", FolderFormats.other(fields: editor.draft.sessionFields))
                    custom
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 420)
            Divider()
            HStack {
                Button { move(-1) } label: { Label("inspector.folder.up", systemImage: "arrow.up") }
                    .disabled(index == 0)
                Button { move(1) } label: { Label("inspector.folder.down", systemImage: "arrow.down") }
                    .disabled(index >= editor.folderLevels.count - 1)
                Spacer()
                Button("inspector.folder.remove", role: .destructive, action: onRemove)
                    .disabled(editor.folderLevels.count <= 1)
            }
        }
        .padding(18)
        .frame(width: 400)
        .spacedLabels()
        .onAppear { customizing = !isReady(current) }
    }

    // MARK: Topo

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("inspector.folder.title \(index + 1)").font(.headline)
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").font(.title).foregroundStyle(.tint)
                Text(example.isEmpty ? String(localized: "inspector.folder.empty") : example)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(example.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
        }
    }

    // MARK: Prontos

    private func group(_ title: LocalizedStringKey, _ formats: [FolderFormat]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 2)
            ForEach(formats) { f in
                FormatRow(example: render(f.segments).nilIfEmpty ?? f.fallback, detail: f.detail,
                          on: f.segments == current) {
                    editor.folderLevels[index] = f.segments
                    customizing = false
                }
            }
        }
    }

    private func isReady(_ segs: [TemplateSegment]) -> Bool {
        (FolderFormats.date + FolderFormats.other(fields: editor.draft.sessionFields)).contains { $0.segments == segs }
    }

    // MARK: Personalizar

    @ViewBuilder private var custom: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.smooth(duration: 0.2)) { customizing.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                        .rotationEffect(.degrees(customizing ? 90 : 0))
                    Text("folder.custom").font(.subheadline.weight(.semibold))
                    if !isReady(current) && !current.isEmpty {
                        Text("folder.custom.inUse").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    }
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if customizing {
                CustomPiecesBuilder(segments: Binding(get: { editor.folderLevels[safe: index] ?? [] },
                                                      set: { editor.folderLevels[index] = $0 }),
                                    fields: editor.draft.sessionFields, defaultSeparator: " ",
                                    value: { render([.token(name: $0, modifiers: [])]) })
            }
        }
    }

    private func move(_ delta: Int) {
        let j = index + delta
        guard editor.folderLevels.indices.contains(j) else { return }
        editor.folderLevels.swapAt(index, j)
    }
}

// MARK: - Nome do arquivo

/// Editor do nome do arquivo: formatos prontos com o nome real e "Personalizar", como o da pasta.
struct FileNameEditor: View {
    @Bindable var editor: PresetEditorModel
    let example: String
    let render: ([TemplateSegment]) -> String
    @State private var customizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("inspector.fileName").font(.headline)
            HStack(spacing: 10) {
                Image(systemName: "doc.fill").font(.title).foregroundStyle(.tint)
                Text(verbatim: example).font(.system(.body, design: .monospaced).weight(.semibold))
                    .lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(NameFormats.all) { f in
                        FormatRow(example: render(f.segments).nilIfEmpty ?? f.fallback, detail: f.detail,
                                  on: f.segments == editor.nameSegments, monospaced: true) {
                            editor.nameSegments = f.segments
                            customizing = false
                        }
                    }
                    Button { withAnimation(.smooth(duration: 0.2)) { customizing.toggle() } } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "chevron.right").font(.caption.weight(.bold))
                                .rotationEffect(.degrees(customizing ? 90 : 0))
                            Text("folder.custom").font(.subheadline.weight(.semibold))
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    if customizing {
                        CustomPiecesBuilder(segments: $editor.nameSegments, fields: editor.draft.sessionFields,
                                            defaultSeparator: "_",
                                            value: { (render([.token(name: $0, modifiers: [])]) as NSString).deletingPathExtension })
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 420)
            if editor.nameMayRepeat {
                Label("preset.rename.notUniqueHint", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 420)
        .spacedLabels()
        .onAppear { customizing = !NameFormats.all.contains { $0.segments == editor.nameSegments } }
    }
}

enum NameFormats {
    private static func t(_ n: String) -> TemplateSegment { .token(name: n, modifiers: []) }
    private static let u = TemplateSegment.literal("_")

    static let all: [FolderFormat] = [
        .init(id: "p-orig", segments: [t("projeto"), u, t("nome_original")], detail: "name.fmt.projectOriginal", fallback: "Projeto_C0001"),
        .init(id: "p-data-hora-orig", segments: [t("projeto"), u, t("data"), u, t("hora"), u, t("nome_original")], detail: "name.fmt.projectDateOriginal", fallback: "Projeto_2026-05-28_17h26_C0001"),
        .init(id: "p-cam-cont", segments: [t("projeto"), u, t("camera"), u, t("contador")], detail: "name.fmt.projectCameraCounter", fallback: "Projeto_CAM A_0001"),
        .init(id: "data-cam-cont", segments: [t("data"), u, t("camera"), u, t("contador")], detail: "name.fmt.dateCameraCounter", fallback: "2026-05-28_CAM A_0001"),
        .init(id: "cam-orig", segments: [t("camera"), u, t("nome_original")], detail: "name.fmt.cameraOriginal", fallback: "CAM A_C0001"),
        .init(id: "cartao-orig", segments: [t("cartao"), u, t("nome_original")], detail: "name.fmt.cardOriginal", fallback: "A001_C0001"),
    ]
}

// MARK: - Linha de formato

private struct FormatRow: View {
    let example: String
    let detail: LocalizedStringKey
    let on: Bool
    var monospaced = false
    let action: () -> Void
    @State private var hovering = false

    private var exampleText: some View {
        Text(example)
            .font(monospaced ? .system(.callout, design: .monospaced) : .body)
            .fontWeight(on ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.5))
                if monospaced {
                    // nome de arquivo é comprido: exemplo inteiro numa linha, o que ele é embaixo
                    VStack(alignment: .leading, spacing: 1) {
                        exampleText
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                } else {
                    exampleText
                    Spacer(minLength: 8)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(on ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(hovering ? 0.08 : 0),
                        in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Personalizado

/// Nome montado como frase (pasta ou arquivo): peças (com ✕ pra tirar) e textos fixos editáveis, na
/// ordem; embaixo, o que adicionar e o que vai entre as peças.
struct CustomPiecesBuilder: View {
    @Binding var segments: [TemplateSegment]
    let fields: [Preset.SessionField]
    let defaultSeparator: String
    /// Valor que a peça tem agora ("Out", "2026"), pra mostrar ao lado do nome.
    let value: (String) -> String

    private var parts: FolderParts { FolderParts(segments, defaultSeparator: defaultSeparator) }
    private func update(_ change: (inout FolderParts) -> Void) {
        var p = parts
        change(&p)
        segments = p.segments
    }

    /// "Mês curto · Out" no menu de adicionar.
    private func menuTitle(_ label: String, _ v: String) -> String { v.isEmpty || v == label ? label : "\(label) · \(v)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                if parts.items.isEmpty {
                    Text("folder.custom.empty").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(parts.items.enumerated()), id: \.offset) { i, item in
                    switch item {
                    case .token(let name, _):
                        HStack(spacing: 5) {
                            Image(systemName: TokenCatalog.info(for: name)?.systemImage ?? "tag").font(.caption)
                            Text(FolderFormats.label(name, fields: fields))
                            let v = value(name)
                            if !v.isEmpty { Text(v).foregroundStyle(.secondary) }
                            Button { update { $0.items.remove(at: i) } } label: {
                                Image(systemName: "xmark").font(.caption2.weight(.bold)).accessibilityLabel(Text("folder.custom.remove"))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("folder.custom.remove")
                        }
                        .font(.callout)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15), in: .capsule)
                    case .text(let t):
                        HStack(spacing: 4) {
                            DeferredTextField("folder.custom.textPlaceholder", text: Binding(
                                get: { t },
                                set: { v in update { $0.items[i] = .text(v) } }))
                                .textFieldStyle(.plain)
                                .frame(width: max(50, CGFloat(t.count) * 8 + 16))
                            Button { update { $0.items.remove(at: i) } } label: {
                                Image(systemName: "xmark").font(.caption2.weight(.bold)).accessibilityLabel(Text("folder.custom.remove"))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    }
                }
            }
            HStack(spacing: 8) {
                Menu {
                    ForEach(TokenCatalog.categoryOrder, id: \.self) { cat in
                        Section(LocalizedStringKey(cat)) {
                            ForEach(TokenCatalog.all.filter { $0.category == cat }, id: \.name) { t in
                                Button { update { $0.items.append(.token(t.name, [])) } } label: {
                                    Label(menuTitle(String(localized: String.LocalizationValue(t.label)), value(t.name)),
                                          systemImage: t.systemImage)
                                }
                            }
                        }
                    }
                    if !fields.isEmpty {
                        Section("inspector.fields") {
                            ForEach(fields, id: \.key) { f in
                                Button(menuTitle(f.label.isEmpty ? f.key : f.label, value(f.key))) {
                                    update { $0.items.append(.token(f.key, [])) }
                                }
                            }
                        }
                    }
                } label: {
                    Label("folder.custom.addPiece", systemImage: "plus")
                }
                .fixedSize()
                Button { update { $0.items.append(.text("")) } } label: {
                    Label("folder.custom.addText", systemImage: "character.cursor.ibeam")
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("folder.custom.between").font(.subheadline).foregroundStyle(.secondary)
                Picker("folder.custom.between", selection: Binding(get: { parts.separator },
                                                                    set: { v in update { $0.separator = v } })) {
                    Text("folder.sep.space").tag(" ")
                    Text(verbatim: "-").tag("-")
                    Text(verbatim: "_").tag("_")
                    Text("folder.sep.none").tag("")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
    }
}

// MARK: - Formatos

struct FolderFormat: Identifiable {
    let id: String
    let segments: [TemplateSegment]
    let detail: LocalizedStringKey
    /// Texto quando o exemplo não pode ser calculado (peça sem valor agora).
    let fallback: String
}

enum FolderFormats {
    private static func t(_ n: String) -> TemplateSegment { .token(name: n, modifiers: []) }
    private static func l(_ s: String) -> TemplateSegment { .literal(s) }

    static let date: [FolderFormat] = [
        .init(id: "d-mabrev-a", segments: [t("dia"), l(" "), t("mes_abrev"), l(" "), t("ano")], detail: "folder.fmt.dayMonthYear", fallback: "28 Mai 2026"),
        .init(id: "a-m-d", segments: [t("ano"), l("-"), t("mes"), l("-"), t("dia")], detail: "folder.fmt.iso", fallback: "2026-05-28"),
        .init(id: "d-m-a", segments: [t("dia"), l("-"), t("mes"), l("-"), t("ano")], detail: "folder.fmt.numeric", fallback: "28-05-2026"),
        .init(id: "mnome-a", segments: [t("mes_nome"), l(" "), t("ano")], detail: "folder.fmt.month", fallback: "Maio 2026"),
        .init(id: "a", segments: [t("ano")], detail: "folder.fmt.year", fallback: "2026"),
        .init(id: "turno", segments: [t("turno")], detail: "folder.fmt.shift", fallback: "Manhã"),
    ]

    static func other(fields: [Preset.SessionField]) -> [FolderFormat] {
        var out: [FolderFormat] = [
            .init(id: "projeto", segments: [t("projeto")], detail: "folder.fmt.project", fallback: "Projeto"),
            .init(id: "tipo", segments: [t("tipo")], detail: "folder.fmt.type", fallback: "Vídeo"),
            .init(id: "cartao", segments: [t("cartao")], detail: "folder.fmt.card", fallback: "A001"),
            .init(id: "camera", segments: [t("camera")], detail: "folder.fmt.camera", fallback: "CAM A"),
            .init(id: "lote", segments: [t("lote")], detail: "folder.fmt.batch", fallback: "Lote 01"),
        ]
        for f in fields where !f.key.isEmpty {
            out.append(.init(id: "field-\(f.key)", segments: [t(f.key)], detail: "folder.fmt.field", fallback: f.label))
        }
        return out
    }

    /// Nome da peça ("Dia", "Mês curto").
    static func label(_ name: String, fields: [Preset.SessionField]) -> String {
        if let f = fields.first(where: { $0.key == name }) { return f.label.isEmpty ? f.key : f.label }
        return Recipe.describe([.token(name: name, modifiers: [])])
    }
}

/// Uma pasta vista como frase: itens (peças e textos) e o que vai entre eles.
struct FolderParts: Equatable {
    enum Item: Equatable { case token(String, [String]); case text(String) }
    var items: [Item] = []
    var separator: String = " "

    private static let separatorChars = Set(" -_.·")
    static func isSeparator(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { separatorChars.contains($0) } }

    init(_ segments: [TemplateSegment], defaultSeparator: String = " ") {
        var sep: String?
        var lastWasItem = false
        for seg in segments {
            switch seg {
            case .token(let n, let m):
                if lastWasItem && sep == nil { sep = "" }
                items.append(.token(n, m)); lastWasItem = true
            case .literal(let s):
                if Self.isSeparator(s) && lastWasItem {
                    if sep == nil { sep = s }
                    lastWasItem = false
                } else {
                    items.append(.text(s)); lastWasItem = true
                }
            }
        }
        separator = sep ?? defaultSeparator
    }

    var segments: [TemplateSegment] {
        var out: [TemplateSegment] = []
        for (i, item) in items.enumerated() {
            if i > 0 && !separator.isEmpty { out.append(.literal(separator)) }
            switch item {
            case .token(let n, let m): out.append(.token(name: n, modifiers: m))
            case .text(let s): out.append(.literal(s))
            }
        }
        return out
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
