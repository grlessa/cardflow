import Foundation
import Sparkle

/// Mantém o updater do Sparkle. No launch faz um probe silencioso (sem UI) que, se achar
/// versão nova, preenche `availableVersion` (lido pelo banner). `install()` abre o fluxo
/// padrão do Sparkle (notas da versão + progresso), que baixa, verifica, instala e reabre o app.
/// É a única parte do app que toca a rede.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// Versão nova (ex.: "1.0.3") quando há atualização; nil caso contrário.
    @Published var availableVersion: String?

    private var controller: SPUStandardUpdaterController!
    private var hasProbed = false

    /// `startingUpdater: false` em teste/captura de tela ou build solto (`swift run`): não toca a rede nem mostra alerta.
    init(startingUpdater: Bool = (Bundle.main.bundleIdentifier != nil)) {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: startingUpdater,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = false
    }

    /// Probe silencioso único na abertura do app (não repete ao fechar e reabrir a janela principal).
    func probeOnce() {
        guard !hasProbed, Bundle.main.bundleIdentifier != nil else { return }
        hasProbed = true
        probe()
    }

    /// Probe silencioso: pergunta ao appcast se há versão nova, sem mostrar nenhuma UI.
    func probe() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        controller.updater.checkForUpdateInformation()
    }

    /// Abre o fluxo do Sparkle (janela com notas + Instalar + progresso). Reabre o app no fim.
    func install() {
        controller.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate (o Sparkle chama estes na main thread)
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let ver = item.displayVersionString
        Task { @MainActor in self.availableVersion = ver }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.availableVersion = nil }
    }
}
