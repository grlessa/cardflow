import SwiftUI

@main
struct CardflowApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 560)
                .onAppear { model.start() }
        }
        .windowResizability(.contentMinSize)
    }
}
