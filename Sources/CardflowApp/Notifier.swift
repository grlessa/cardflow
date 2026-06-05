import Foundation
import UserNotifications

/// Aviso do sistema ao terminar/falhar um offload. No fluxo real de culto a pessoa inicia a cópia
/// (vários minutos) e sai pra desmontar o palco — sem aviso, ela volta tarde ou, pior, desconecta
/// cartão/disco achando que acabou. best-effort: nunca derruba nada, e fora de um app empacotado
/// (ex.: rodando via `swift run`) simplesmente não faz nada.
enum Notifier {
    /// Só usa notificações quando há um bundle de app de verdade (senão UNUserNotificationCenter trava).
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorizationIfNeeded() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
