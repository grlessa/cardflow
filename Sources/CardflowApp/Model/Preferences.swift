import Foundation
import AppKit
import UserNotifications

/// Preferências do app que não são do projeto: idioma, aparência e comportamento ao terminar.
@MainActor enum Preferences {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
    }

    static var appearance: Appearance {
        get { Appearance(rawValue: UserDefaults.standard.string(forKey: "cardflow.appearance") ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "cardflow.appearance"); applyAppearance() }
    }

    @MainActor static func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Idioma só deste app ("" = o do sistema). Vale ao reabrir o app.
    static let languages = ["", "pt-BR", "en", "es"]
    static var language: String {
        get { (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first ?? "" }
        set {
            if newValue.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
            else { UserDefaults.standard.set([newValue], forKey: "AppleLanguages") }
        }
    }

    /// Reabre o app (pra valer o idioma novo).
    @MainActor static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    nonisolated static var playsSound: Bool { UserDefaults.standard.object(forKey: "cardflow.sound") as? Bool ?? true }
    nonisolated static var opensReportWhenDone: Bool { UserDefaults.standard.bool(forKey: "cardflow.openReportWhenDone") }
    nonisolated static var checksUpdatesOnLaunch: Bool { UserDefaults.standard.object(forKey: "cardflow.checkUpdatesOnLaunch") as? Bool ?? true }
}

/// Estado das permissões que o Cardflow usa, pra aba Permissões dos Ajustes.
@MainActor @Observable
final class PermissionsCenter {
    enum State: Equatable { case unknown, granted, denied, notAsked }

    var notifications: State = .unknown
    var externalVolumes: State = .unknown
    var desktopFolders: State = .unknown

    func refresh(volumes: [URL]) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let s: State
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: s = .granted
            case .denied: s = .denied
            default: s = .notAsked
            }
            Task { @MainActor in self.notifications = s }
        }
        probe(volumes, into: \.externalVolumes)
        let home = FileManager.default.homeDirectoryForCurrentUser
        probe([home.appendingPathComponent("Desktop"), home.appendingPathComponent("Documents")], into: \.desktopFolders)
    }

    /// Lê a pasta em segundo plano: na primeira vez o macOS pergunta; depois, a leitura diz se pode.
    func probe(_ urls: [URL], into key: ReferenceWritableKeyPath<PermissionsCenter, State>) {
        guard !urls.isEmpty else { self[keyPath: key] = .unknown; return }
        Task.detached {
            let ok = urls.allSatisfy { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil }
            await MainActor.run { self[keyPath: key] = ok ? .granted : .denied }
        }
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.refresh(volumes: []) }
        }
    }

    static func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}
