import Foundation
import CoreServices

/// Avisa quando algo muda dentro de uma pasta (FSEvents, o mesmo que o Finder usa). Várias mudanças
/// seguidas viram um aviso só (`latency`), pra uma cópia de 200 arquivos pro cartão não pedir 200 releituras.
@MainActor
final class FolderWatcher {
    private final class CallbackBox {
        var onChange: (@MainActor () -> Void)?
        init(_ onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
    }

    private var stream: FSEventStreamRef?
    private let box: CallbackBox

    init?(path: String, latency: TimeInterval = 1.5, onChange: @escaping @MainActor () -> Void) {
        let box = CallbackBox(onChange)
        self.box = box
        let retain: CFAllocatorRetainCallBack = { ptr in
            guard let ptr else { return nil }
            _ = Unmanaged<CallbackBox>.fromOpaque(ptr).retain()
            return ptr
        }
        let release: CFAllocatorReleaseCallBack = { ptr in
            guard let ptr else { return }
            Unmanaged<CallbackBox>.fromOpaque(ptr).release()
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: retain, release: release, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { box.onChange?() }
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { stop(); return nil }
    }

    func stop() {
        box.onChange = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    nonisolated deinit {
        // Caso o dono tenha esquecido de chamar stop(), limpa o callback e agenda a soltura do stream na main.
        // Como o FSEventStreamContext retém `box`, não há ponteiro solto mesmo se deinit rodar fora da main.
        let b = box
        Task { @MainActor in b.onChange = nil }
    }
}
