import SwiftUI
import OffloadKit

/// Ajustes (⌘,): Geral, Cópia, Permissões e Atualizações.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("settings.general", systemImage: "gearshape") { GeneralSettings() }
            Tab("settings.copy", systemImage: "doc.on.doc") { CopySettings() }
            Tab("settings.permissions", systemImage: "lock.shield") { PermissionsSettings() }
            Tab("settings.updates", systemImage: "arrow.down.circle") { UpdateSettings() }
        }
        .frame(width: 560)
        .spacedLabels()
    }
}

// MARK: - Geral

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var language = Preferences.language
    @State private var appearance = Preferences.appearance
    private let startLanguage = Preferences.language

    var body: some View {
        Form {
            Section {
                Picker("settings.language", selection: $language) {
                    Text("settings.language.system").tag("")
                    Text(verbatim: "Português (Brasil)").tag("pt-BR")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Español").tag("es")
                }
                .onChange(of: language) { Preferences.language = language }
                if language != startLanguage {
                    LabeledContent {
                        Button("settings.language.relaunch") { Preferences.relaunch() }
                    } label: {
                        Text("settings.language.pending")
                    }
                }
                Picker("settings.appearance", selection: $appearance) {
                    Text("settings.appearance.system").tag(Preferences.Appearance.system)
                    Text("settings.appearance.light").tag(Preferences.Appearance.light)
                    Text("settings.appearance.dark").tag(Preferences.Appearance.dark)
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { Preferences.appearance = appearance }
            }
            Section {
                LabeledContent {
                    Button("settings.guide.open") { model.showOnboarding = true }
                } label: {
                    SettingLabel("menu.help.guide", help: "settings.guide.help")
                }
            }
            Section {
                LabeledContent {
                    Button { NSWorkspace.shared.open(Links.support) } label: { Label("sidebar.support", systemImage: "heart") }
                } label: {
                    SettingLabel("settings.support", help: "sidebar.support.help")
                }
            }
        }
        .settingsPane()
    }
}

// MARK: - Cópia

private struct CopySettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("cardflow.ejectWhenDone") private var ejectWhenDone = true
    @AppStorage("cardflow.notify") private var notify = true
    @AppStorage("cardflow.sound") private var sound = true
    @AppStorage("cardflow.openReportWhenDone") private var openReport = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker(selection: Binding(get: { model.defaultMediaChoice },
                                          set: { model.defaultMediaChoice = $0; model.savePresetSelection() })) {
                    Text("main.media.photo").tag(Preset.Media.Kind.photo)
                    Text("main.media.video").tag(Preset.Media.Kind.video)
                    Text("main.media.audio").tag(Preset.Media.Kind.audio)
                    Text("main.media.all").tag(Preset.Media.Kind.both)
                } label: {
                    SettingLabel("settings.copy.defaultMedia", help: "settings.copy.defaultMedia.help")
                }
            }
            Section("settings.copy.whenDone") {
                Toggle(isOn: $ejectWhenDone) { SettingLabel("settings.copy.eject", help: "settings.copy.eject.help") }
                Toggle(isOn: $notify) { SettingLabel("settings.copy.notify", help: "settings.copy.notify.help") }
                Toggle("settings.copy.sound", isOn: $sound)
                    .disabled(!notify)
                Toggle(isOn: $openReport) { SettingLabel("settings.copy.openReport", help: "settings.copy.openReport.help") }
            }
        }
        .settingsPane()
    }
}

// MARK: - Permissões

private struct PermissionsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var center = PermissionsCenter()

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("settings.permissions.grantAll") { grantAll() }
                        .buttonStyle(.borderedProminent)
                } label: {
                    SettingLabel("settings.permissions.title", help: "settings.permissions.help")
                }
            }
            Section {
                row("settings.permissions.notifications", help: "settings.permissions.notifications.help",
                    symbol: "bell.badge", state: center.notifications) {
                    if center.notifications == .denied { PermissionsCenter.openPrivacy("Notifications") }
                    else { center.requestNotifications() }
                }
                row("settings.permissions.volumes", help: "settings.permissions.volumes.help",
                    symbol: "externaldrive", state: center.externalVolumes) {
                    if center.externalVolumes == .denied { PermissionsCenter.openPrivacy("Privacy_FilesAndFolders") }
                    else { center.probe(externalVolumes, into: \.externalVolumes) }
                }
                row("settings.permissions.folders", help: "settings.permissions.folders.help",
                    symbol: "folder", state: center.desktopFolders) {
                    if center.desktopFolders == .denied { PermissionsCenter.openPrivacy("Privacy_FilesAndFolders") }
                    else { center.refresh(volumes: externalVolumes) }
                }
            }
            Section {
                FormatActivationRow()
            } header: {
                Text("settings.permissions.format")
            } footer: {
                Text("format.settings.explainer").foregroundStyle(.secondary)
            }
        }
        .settingsPane()
        .onAppear { center.refresh(volumes: externalVolumes) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            center.refresh(volumes: externalVolumes)
        }
    }

    private var externalVolumes: [URL] { model.watcher.volumes.map(\.url) }

    private func grantAll() {
        if center.notifications != .granted { center.requestNotifications() }
        center.refresh(volumes: externalVolumes)
        if model.formatter.permission == .notActivated { model.formatter.activate() }
        else if model.formatter.permission == .needsApproval { model.formatter.openSystemSettings() }
        else if model.formatter.permission == .needsDiskAccess { model.formatter.openDiskAccessSettings() }
    }

    @ViewBuilder
    private func row(_ title: LocalizedStringKey, help: LocalizedStringKey, symbol: String,
                     state: PermissionsCenter.State, action: @escaping () -> Void) -> some View {
        LabeledContent {
            switch state {
            case .granted:
                Label("settings.permissions.granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .denied:
                Button("settings.permissions.openSettings", action: action)
            case .notAsked, .unknown:
                Button("settings.permissions.allow", action: action)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(help).font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol).foregroundStyle(.tint).frame(width: 20)
            }
        }
    }
}

// MARK: - Atualizações

private struct UpdateSettings: View {
    @EnvironmentObject private var updates: UpdateController
    @AppStorage("cardflow.checkUpdatesOnLaunch") private var checkOnLaunch = true

    var body: some View {
        Form {
            Section {
                LabeledContent("settings.updates.version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                        .monospacedDigit()
                }
                Toggle("settings.updates.onLaunch", isOn: $checkOnLaunch)
                LabeledContent {
                    HStack {
                        Button("settings.updates.notes") {
                            NSWorkspace.shared.open(Links.site)
                        }
                        if let v = updates.availableVersion {
                            Button("main.update.install") { updates.install() }.buttonStyle(.borderedProminent)
                                .help(Text("main.update.available \(v)"))
                        } else {
                            Button("settings.updates.check") { updates.install() }
                        }
                    }
                } label: {
                    if let v = updates.availableVersion { Text("main.update.available \(v)") }
                    else { Text("settings.updates.source") }
                }
            }
        }
        .settingsPane()
    }
}

/// Título com explicação embaixo. Em VStack porque o Form agrupado mede errado a legenda nativa
/// (`Toggle { Text; Text }`) e a janela dos Ajustes ficava curta, cortando a última linha.
private struct SettingLabel: View {
    let title: LocalizedStringKey
    let help: LocalizedStringKey
    init(_ title: LocalizedStringKey, help: LocalizedStringKey) { self.title = title; self.help = help }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(help).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private extension View {
    /// Aba dos Ajustes: Form agrupado do tamanho do conteúdo (a janela acompanha a aba, sem rolagem).
    func settingsPane() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}
