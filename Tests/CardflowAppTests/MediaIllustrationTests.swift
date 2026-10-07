import Testing
import SwiftUI
import AppKit
@testable import CardflowApp
@testable import OffloadKit

@MainActor @Suite struct MediaIllustrationTests {
    @Test(arguments: MediaKind.allCases)
    func cadaTipoDesenhaEmTodosOsTamanhos(kind: MediaKind) throws {
        for size in [16.0, 32.0, 64.0, 128.0] {
            let r = ImageRenderer(content: MediaIllustration(kind: kind, size: size, badge: .verified))
            r.scale = 2
            let img = try #require(r.cgImage)
            #expect(img.width == Int(size * 2))
        }
    }

    /// Folha de contato pra conferência visual: CARDFLOW_SNAPSHOT_DIR=/caminho swift test --filter folhaDeContato
    @Test func folhaDeContato() throws {
        guard let dir = ProcessInfo.processInfo.environment["CARDFLOW_SNAPSHOT_DIR"] else { return }
        for scheme in [ColorScheme.light, .dark] {
            let sheet = VStack(alignment: .leading, spacing: 22) {
                ForEach([128.0, 64, 32, 16], id: \.self) { size in
                    HStack(spacing: 18) {
                        ForEach(MediaKind.allCases, id: \.self) { k in
                            MediaIllustration(kind: k, size: size,
                                              badge: size == 64 ? .verified : (size == 32 ? .progress(0.6) : nil))
                        }
                    }
                }
            }
            .padding(28)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: sheet)
            r.scale = 2
            let rep = NSBitmapImageRep(cgImage: try #require(r.cgImage))
            try rep.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("midias-\(scheme == .dark ? "escuro" : "claro").png"))
        }
    }
}
