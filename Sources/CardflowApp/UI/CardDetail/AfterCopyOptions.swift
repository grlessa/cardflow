import SwiftUI

/// "Ao terminar": formatar e ejetar o cartão, duas escolhas iguais, desenhadas como os blocos de "O que
/// copiar". Formatar vale só nesta sessão (sempre começa desligado); ejetar é lembrado entre aberturas.
struct AfterCopyOptions: View {
    @Environment(AppModel.self) private var model
    @AppStorage("cardflow.ejectWhenDone") private var ejectWhenDone = true
    let card: CardSession

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { tiles.frame(minWidth: 220) }
            VStack(spacing: 10) { tiles }
        }
        .disabled(card.isBusy)
    }

    @ViewBuilder private var tiles: some View {
        Button(action: toggleFormat) {
            OptionTile(symbol: "sparkles", title: "after.format.title", detail: formatDetail,
                       on: formatOn, attention: formatNeedsActivation)
        }
        .buttonStyle(.plain)
        .disabled(formatLockedByCamera || model.formatter.permission == .unavailable)

        Button { ejectWhenDone.toggle() } label: {
            OptionTile(symbol: "eject", title: "after.eject.title",
                       detail: ejectWhenDone ? "after.eject.on" : "after.eject.off", on: ejectWhenDone)
        }
        .buttonStyle(.plain)
    }

    private var formatLockedByCamera: Bool { !card.excludedCameras.isEmpty }
    private var formatNeedsActivation: Bool { !model.formattingAvailable && model.formatter.permission != .unavailable }
    private var formatOn: Bool { model.autoFormatThisSession && model.formattingAvailable && !formatLockedByCamera }

    private var formatDetail: LocalizedStringKey {
        if model.formatter.permission == .unavailable { return "after.format.unavailable" }
        if formatLockedByCamera { return "after.format.lockedCamera" }
        if formatNeedsActivation { return "after.format.activate" }
        return formatOn ? "after.format.on" : "after.format.off"
    }

    private func toggleFormat() {
        if formatNeedsActivation { model.formatter.activate(); return }
        model.autoFormatThisSession.toggle()
    }
}

/// Bloco de escolha liga/desliga, no mesmo desenho dos blocos de mídia.
private struct OptionTile: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let on: Bool
    var attention = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(attention ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.5))
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(hovering ? 0.10 : 0.05),
                    in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(on ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.2), lineWidth: on ? 1.5 : 1))
        .contentShape(.rect(cornerRadius: 12))
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: on)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
