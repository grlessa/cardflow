import SwiftUI

@main
struct CardflowApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 720)   // min REAL da janela (com .contentMinSize)
                .onAppear { model.start() }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 800)            // tamanho de abertura confortável
    }
}
