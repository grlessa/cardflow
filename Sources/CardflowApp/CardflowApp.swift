import SwiftUI

@main
struct CardflowApp: App {
    @State private var model = AppModel()
    @StateObject private var updates = UpdateController()
    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(model)
                .environmentObject(updates)
                .frame(minWidth: 820, minHeight: 720)
                .onAppear { model.start(); updates.probe() }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 800)
    }
}
