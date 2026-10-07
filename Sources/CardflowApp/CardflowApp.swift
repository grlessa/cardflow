import SwiftUI

@main
struct CardflowApp: App {
    @State private var model = AppModel()
    @StateObject private var updates = UpdateController()
    var body: some Scene {
        // janela única: o app é um painel de trabalho, não documentos. Fechada, volta pelo menu Janela
        // ou pelo Dock, e não abre abas.
        Window("Cardflow", id: "main") {
            RootView()
                .environment(model)
                .environmentObject(updates)
                .onAppear {
                    Preferences.applyAppearance()
                    model.start()
                    if Preferences.checksUpdatesOnLaunch { updates.probe() }
                }
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CardflowCommands(model: model, updates: updates)
            SidebarCommands()
        }
        Settings {
            SettingsView()
                .environment(model)
                .environmentObject(updates)
        }
    }
}
