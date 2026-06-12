import Foundation
import Sparkle

/// Mantém o updater do Sparkle. No launch faz um probe silencioso (sem UI) que, se achar
/// versão nova, preenche `availableVersion` — é o que o banner lê. `install()` abre o fluxo
/// padrão do Sparkle (notas da versão + progresso), que baixa, verifica, instala e reabre o app.
/// É a única parte do app que toca a rede.
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// Versão nova (ex.: "0.2.0") quando há atualização; nil caso contrário.
    @Published var availableVersion: String?

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        // controller criado depois do super.init pra poder passar self como delegate.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: nil)
        // a gente dirige a checagem (probe no launch); sem agendamento nem prompt de 1ª execução.
        controller.updater.automaticallyChecksForUpdates = false
    }

    /// Probe silencioso: pergunta ao appcast se há versão nova, sem mostrar nenhuma UI.
    func probe() {
        controller.updater.checkForUpdateInformation()
    }

    /// Abre o fluxo do Sparkle (janela com notas + Instalar + progresso). Reabre o app no fim.
    func install() {
        controller.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate (o Sparkle chama estes na main thread)
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
    }
}
