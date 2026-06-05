import Foundation

/// Cópia + verificação de um arquivo. Protocolo pra permitir injetar um copiador de teste
/// (ex.: que força o verify a falhar) e cobrir o caminho crítico de detecção de corrupção.
public protocol FileCopying {
    @discardableResult
    func copy(source: URL, to destinations: [URL], onChunk: (Int) -> Void, isCancelled: () -> Bool) throws -> UInt64
    func verify(expectedHash: UInt64, fileAt url: URL) throws -> Bool
}

public struct FileCopier: FileCopying {
    private let chunkSize: Int
    public init(chunkSize: Int = 1 << 22) { self.chunkSize = chunkSize }   // 4 MB

    /// Lê a origem UMA vez: grava em todos os destinos e calcula o xxHash64 da origem no caminho.
    /// Cria os diretórios intermediários. Retorna o hash da origem.
    /// `onChunk` recebe o nº de bytes de cada bloco gravado — pra mostrar progresso DENTRO de um
    /// arquivo grande (senão a barra fica parada até o arquivo inteiro terminar).
    @discardableResult
    public func copy(source: URL, to destinations: [URL], onChunk: (Int) -> Void = { _ in },
                     isCancelled: () -> Bool = { false }) throws -> UInt64 {
        let fm = FileManager.default
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }

        var writers: [FileHandle] = []
        for dest in destinations {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: dest.path, contents: nil)
            writers.append(try FileHandle(forWritingTo: dest))
        }
        defer { for w in writers { try? w.close() } }

        var hasher = XXHash64()
        var done = false
        while !done {
            // Parar responsivo: checa cancelamento a cada bloco (não só entre arquivos), pra interromper
            // no meio de um vídeo grande. O parcial em escrita é varrido depois (atomicidade garante segurança).
            if isCancelled() { throw CancellationError() }
            // autoreleasepool: sem ele, os `Data` autoreleased de cada read acumulam na
            // memória em thread de fundo (copiando dezenas de GB = dezenas de GB de RAM).
            try autoreleasepool {
                guard let data = try reader.read(upToCount: chunkSize), !data.isEmpty else { done = true; return }
                data.withUnsafeBytes { hasher.update($0) }
                for w in writers { try w.write(contentsOf: data) }
                onChunk(data.count)
            }
        }
        // fsync: empurra os bytes pra fora do cache de página antes da conferência, pra a releitura
        // valer (a conferência relê e o hash não bate se a gravação saiu errada). Nota: fsync não força
        // o cache interno do drive (isso seria F_FULLFSYNC, bem mais lento) — suficiente pro nosso verify.
        for w in writers { try w.synchronize() }

        // preserva data de modificação/criação da origem (uma cópia do Finder faz isso). Sem isto,
        // tudo ficaria datado do momento do offload, quebrando "ordenar por data" no Finder. Não afeta
        // a conferência (que confere o CONTEÚDO, não a metadata). best-effort: nunca derruba a cópia.
        if let attrs = try? fm.attributesOfItem(atPath: source.path) {
            var keep: [FileAttributeKey: Any] = [:]
            if let m = attrs[.modificationDate] { keep[.modificationDate] = m }
            if let c = attrs[.creationDate] { keep[.creationDate] = c }
            if !keep.isEmpty { for dest in destinations { try? fm.setAttributes(keep, ofItemAtPath: dest.path) } }
        }
        return hasher.finalize()
    }

    /// Lê o arquivo de destino e confirma que o hash bate com o esperado.
    public func verify(expectedHash: UInt64, fileAt url: URL) throws -> Bool {
        try XXHash64.hash(fileAt: url) == expectedHash
    }
}
