import Foundation

public struct FileCopier {
    private let chunkSize: Int
    public init(chunkSize: Int = 1 << 22) { self.chunkSize = chunkSize }   // 4 MB

    /// Lê a origem UMA vez: grava em todos os destinos e calcula o xxHash64 da origem no caminho.
    /// Cria os diretórios intermediários. Retorna o hash da origem.
    /// `onChunk` recebe o nº de bytes de cada bloco gravado — pra mostrar progresso DENTRO de um
    /// arquivo grande (senão a barra fica parada até o arquivo inteiro terminar).
    @discardableResult
    public func copy(source: URL, to destinations: [URL], onChunk: (Int) -> Void = { _ in }) throws -> UInt64 {
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
            // autoreleasepool: sem ele, os `Data` autoreleased de cada read acumulam na
            // memória em thread de fundo (copiando dezenas de GB = dezenas de GB de RAM).
            try autoreleasepool {
                guard let data = try reader.read(upToCount: chunkSize), !data.isEmpty else { done = true; return }
                data.withUnsafeBytes { hasher.update($0) }
                for w in writers { try w.write(contentsOf: data) }
                onChunk(data.count)
            }
        }
        // fsync: força os bytes do buffer do SO para o disco FÍSICO antes do verify. Sem isso, o verify
        // leria de volta da page cache e passaria mesmo se a mídia ainda não tivesse chegado no SSD/cartão.
        for w in writers { try w.synchronize() }
        return hasher.finalize()
    }

    /// Lê o arquivo de destino e confirma que o hash bate com o esperado.
    public func verify(expectedHash: UInt64, fileAt url: URL) throws -> Bool {
        try XXHash64.hash(fileAt: url) == expectedHash
    }
}
