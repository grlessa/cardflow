import SwiftUI
import OffloadKit

/// Resumo de um cartão que terminou e saiu do Mac. Fica no lugar da tela do cartão até a pessoa fechar ou
/// outro cartão chegar: quem deixou rodando e foi pegar um café volta e vê, sem procurar, que deu certo,
/// o que aconteceu e a que horas.
struct CompletedCardView: View {
    @Environment(AppModel.self) private var model
    let item: CompletedCard

    var body: some View {
        DetailScroll {
            VStack(spacing: 22) {
                CompletionSummary(item: item)
                HStack(spacing: 10) {
                    if !item.manifestPaths.isEmpty {
                        Button { model.openReport(manifestPaths: item.manifestPaths) } label: {
                            Label("recent.openReport", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if let folder = projectFolder {
                        Button { NSWorkspace.shared.open(folder) } label: { Label("recent.openFolder", systemImage: "folder") }
                    }
                    Spacer(minLength: 8)
                    Button("completed.close") { model.dismissCompleted(item.id) }
                        .keyboardShortcut(.cancelAction)
                }
                .controlSize(.large)
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(item.name)
    }

    /// Pasta do projeto no destino: a do registro da cópia (…/Projeto/.cardflow/manifest.json).
    private var projectFolder: URL? {
        if let p = item.manifestPaths.first {
            let project = URL(fileURLWithPath: p).deletingLastPathComponent().deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: project.path) { return project }
        }
        return item.destinations.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Selo, título e as etapas com hora. Serve ao cartão que já saiu e ao que ainda está conectado (`live`):
/// nesse caso formatar e ejetar aparecem como em andamento ou por fazer, e os botões ficam na barra de baixo.
struct CompletionSummary: View {
    @Environment(AppModel.self) private var model
    let item: CompletedCard
    var live = false

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                MediaIllustration(kind: item.mediaKind, size: 96, badge: badge)
                Text(title).font(.largeTitle.weight(.semibold)).multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(item.verdict == .ready ? Color.secondary : Color.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
            .padding(.top, 18)

            VStack(spacing: 0) {
                ForEach(Array(item.steps.enumerated()), id: \.offset) { i, step in
                    if i > 0 { Divider().padding(.leading, 46) }
                    StepRow(step: step, item: item)
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.6)))
            .animation(.smooth(duration: 0.3), value: item.steps)

            if !item.pathSegments.isEmpty {
                PathChips(disk: item.destinations.first.flatMap { model.volume($0) }, segments: item.pathSegments,
                          label: "completed.savedIn")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var badge: IllustrationBadge {
        if item.verdict == .keepCard { return .warning }
        return .verified
    }

    private var title: String {
        if item.verdict == .keepCard { return String(localized: "completed.title.keep \(item.name)") }
        if live && !item.formatted && !item.ejected { return String(localized: "completed.title.copied \(item.name)") }
        return String(localized: "completed.title.ready \(item.name)")
    }

    private var subtitle: String {
        if item.verdict == .keepCard { return String(localized: "completed.sub.keep") }
        if live {
            if item.formatting { return String(localized: "completed.sub.live.formatting") }
            if item.formatted { return String(localized: "completed.sub.live.formatted") }
            return item.steps.contains { $0.kind == .formatted }
                ? String(localized: "completed.sub.live.choose") : String(localized: "completed.sub.live.eject")
        }
        switch (item.formatted, item.ejected) {
        case (true, true): return String(localized: "completed.sub.formattedEjected")
        case (false, true): return String(localized: "completed.sub.ejected")
        case (true, false): return String(localized: "completed.sub.formatted")
        case (false, false): return String(localized: "completed.sub.saved")
        }
    }
}

/// Uma etapa do resumo: o visto verde e a hora quando feita, o indicador girando quando em andamento,
/// e um círculo vazio quando ainda está por fazer.
private struct StepRow: View {
    let step: CompletedCard.Step
    let item: CompletedCard

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                switch step.state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .running: ProgressView().controlSize(.small)
                case .pending: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                }
            }
            .font(.title3)
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(step.state == .pending ? .secondary : .primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if step.state == .done, let at = step.at {
                Text(at.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch (step.kind, step.state) {
        case (.copied, _): String(localized: "completed.step.copied")
        case (.alreadyThere, _): String(localized: "completed.step.alreadyThere")
        case (.verified, _): String(localized: "completed.step.verified")
        case (.formatted, .done): String(localized: "completed.step.formatted")
        case (.formatted, .running): String(localized: "completed.step.formatting")
        case (.formatted, .pending): String(localized: "completed.step.format")
        case (.ejected, .done): String(localized: "completed.step.ejected")
        case (.ejected, _): String(localized: "completed.step.eject")
        }
    }

    private var detail: String {
        switch (step.kind, step.state) {
        case (.copied, _), (.alreadyThere, _):
            String(localized: "completed.files \(item.files)") + " · " + Format.bytes(item.bytes)
        case (.verified, _): String(localized: "completed.verified.detail \(max(1, item.destinations.count))")
        case (.formatted, .done): String(localized: "completed.formatted.detail \(item.fileSystem ?? "exFAT")")
        case (.formatted, .running): String(localized: "completed.running.format")
        case (.formatted, .pending): String(localized: "completed.pending.format")
        case (.ejected, .done): String(localized: "completed.ejected.detail")
        case (.ejected, _): String(localized: "completed.pending.eject")
        }
    }
}

/// Linha na barra lateral de um cartão concluído que já saiu do Mac.
struct CompletedRow: View {
    let item: CompletedCard

    var body: some View {
        HStack(spacing: 10) {
            MediaIllustration(kind: item.mediaKind, size: 30, badge: item.verdict == .ready ? .verified : .warning)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(item.verdict == .ready ? Color.green : Color.orange)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        if item.verdict == .keepCard { return String(localized: "completed.status.keep") }
        return item.formatted ? String(localized: "completed.status.formatted") : String(localized: "completed.status.done")
    }
}
