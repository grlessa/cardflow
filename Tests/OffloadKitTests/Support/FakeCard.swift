import Foundation

/// Cria uma árvore temporária que imita um cartão de câmera, com um item de cada tipo.
struct FakeCard {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("card-" + UUID().uuidString)
        let fm = FileManager.default
        func write(_ relPath: String, _ bytes: Int, date: Date) throws {
            let url = root.appendingPathComponent(relPath)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data((0..<bytes).map { UInt8(($0 * 7 + relPath.count) & 0xFF) })
            try data.write(to: url)
            try fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        }
        let base = Date(timeIntervalSince1970: 1_780_000_000) // determinístico
        try write("DCIM/100MSDCF/DSC00001.JPG", 2048, date: base)
        try write("DCIM/100MSDCF/DSC00002.JPG", 1024, date: base.addingTimeInterval(60))
        try write("PRIVATE/M4ROOT/CLIP/C0001.MP4", 4096, date: base.addingTimeInterval(120))
        try write("PRIVATE/M4ROOT/CLIP/C0001M01.XML", 256, date: base.addingTimeInterval(120))
        try write("DCIM/100MSDCF/.DS_Store", 32, date: base)
        try write("MISC/notas.txt", 64, date: base)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
