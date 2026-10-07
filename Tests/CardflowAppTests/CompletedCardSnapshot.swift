import Testing
import AppKit
import SwiftUI
@testable import CardflowApp
@testable import OffloadKit

/// Captura da tela de conclusão pra revisão visual. Só roda com CARDFLOW_SNAPSHOT_DIR definido.
@MainActor @Suite struct CompletedCardSnapshot {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CARDFLOW_SNAPSHOT_DIR"] != nil))
    func captura() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CARDFLOW_SNAPSHOT_DIR"]!)
        let t = Calendar.current.date(bySettingHour: 14, minute: 2, second: 0, of: Date())!
        let model = AppModel(formatter: FakeFormatter())
        let items: [(String, CompletedCard)] = [
            ("pronto", CompletedCard(id: "1", name: "A001", mediaKind: .sd, files: 48, bytes: 22_210_000_000,
                                     destinations: [URL(fileURLWithPath: "/Volumes/eLESSA_03")],
                                     steps: [.init(kind: .copied, at: t), .init(kind: .verified, at: t.addingTimeInterval(420)),
                                             .init(kind: .formatted, at: t.addingTimeInterval(470)),
                                             .init(kind: .ejected, at: t.addingTimeInterval(475))],
                                     verdict: .ready, fileSystem: "exFAT", manifestPaths: ["/tmp/x/.cardflow/m.json"],
                                     pathSegments: ["Projeto", "06 Out 2026", "Vídeo"])),
            ("manter", CompletedCard(id: "2", name: "B002", mediaKind: .sd, files: 23, bytes: 5_600_000_000,
                                     destinations: [], steps: [.init(kind: .copied, at: t), .init(kind: .verified, at: t),
                                                               .init(kind: .ejected, at: t)],
                                     verdict: .keepCard, fileSystem: nil, manifestPaths: [], pathSegments: []))
        ]
        for (name, item) in items {
            for dark in [false, true] {
                let view = CompletedCardView(item: item).environment(model).frame(width: 860, height: 760)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 860, height: 760)
                let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                win.contentView = host
                win.setFrameOrigin(NSPoint(x: -4000, y: 0))
                win.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: dir.appendingPathComponent("concluido-\(name)-\(dark ? "escuro" : "claro").png"))
                win.orderOut(nil)
            }
        }
    }
}
