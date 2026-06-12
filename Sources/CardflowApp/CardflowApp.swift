import SwiftUI

enum AppWindowSize {
    static let minimum = CGSize(width: 960, height: 780)
    static let preferred = CGSize(width: 1120, height: 860)
}

@main
struct CardflowApp: App {
    @State private var model = AppModel()
    @StateObject private var updates = UpdateController()
    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(model)
                .environmentObject(updates)
                .frame(minWidth: AppWindowSize.minimum.width, minHeight: AppWindowSize.minimum.height)
                .onAppear { model.start(); updates.probe() }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: AppWindowSize.preferred.width, height: AppWindowSize.preferred.height)
    }
}
