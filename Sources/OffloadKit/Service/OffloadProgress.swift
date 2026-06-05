import Foundation

public struct OffloadProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case scanning, copying, verifying, done
        /// Ordem das fases — pra a UI ignorar progresso fora de ordem (não deixar a barra recuar).
        public var order: Int {
            switch self { case .scanning: 0; case .copying: 1; case .verifying: 2; case .done: 3 }
        }
    }
    public var phase: Phase
    public var filesDone: Int
    public var filesTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public init(phase: Phase, filesDone: Int, filesTotal: Int, bytesDone: Int64, bytesTotal: Int64) {
        self.phase = phase; self.filesDone = filesDone; self.filesTotal = filesTotal
        self.bytesDone = bytesDone; self.bytesTotal = bytesTotal
    }
}
