import SwiftUI

/// Menus do app: Arquivo (modelos e destinos), Cartão (copiar, parar, formatar, ejetar), Visualizar
/// (painel do modelo) e Ajuda (guia rápido).
struct CardflowCommands: Commands {
    let model: AppModel
    let updates: UpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("menu.app.checkUpdates") { updates.install() }
            Button("menu.app.support") { NSWorkspace.shared.open(Links.support) }
        }
        CommandGroup(replacing: .newItem) {
            Button("menu.file.newModel") { model.requestNewModel() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("menu.file.importModel") { model.requestImportModel() }
            Button("menu.file.exportModel") { model.requestExportModel() }
            Button("models.manage.menu") { model.requestManageModels() }
            Divider()
            Button("menu.file.addDestination") { model.requestAddDestination() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
        CommandMenu("menu.card") {
            Button("menu.card.copy") { if let c = model.selectedCard { model.enqueueCopy(c) } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!(model.selectedCard.map(model.canStart) ?? false))
            Button("menu.card.copyAll") { model.enqueueAll() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(model.readyToCopyCount == 0)
            Button("menu.card.stop") { if let c = model.selectedCard { model.cancelOffload(c) } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!(model.selectedCard?.isRunning ?? false) && model.selectedCard?.phase != .queued)
            Divider()
            Button("menu.card.format") { if let c = model.selectedCard { model.startFormatFlow(c) } }
                .disabled(!model.canFormat(model.selectedCard))
            Button("menu.card.eject") { if let c = model.selectedCard { Task { await model.eject(c) } } }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.selectedCard == nil || model.selectedCard?.isBusy == true)
            Button("menu.card.revealInFinder") { if let c = model.selectedCard { model.revealInFinder(c) } }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.selectedCard == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(model.inspectorShown ? "menu.view.hideModel" : "menu.view.showModel") { model.setInspector(!model.inspectorShown) }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("menu.help.guide") { model.showOnboarding = true }
            Button("menu.help.site") { NSWorkspace.shared.open(Links.site) }
        }
    }
}
