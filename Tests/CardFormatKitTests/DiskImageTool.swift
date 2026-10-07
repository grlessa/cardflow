import Foundation

/// Utilitário de TESTE: anexa um arquivo como disco (sem montar), monta/desmonta e roda ferramentas.
enum DiskImageTool {
    struct Attached { let wholeDisk: String }   // ex.: "disk7"

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> (status: Int32, out: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    static func attach(_ imagePath: String) throws -> Attached {
        let r = try run("/usr/bin/hdiutil", ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", imagePath])
        guard r.status == 0,
              let line = r.out.split(separator: "\n").first(where: { $0.hasPrefix("/dev/disk") }),
              let dev = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
            throw NSError(domain: "DiskImageTool", code: 1, userInfo: [NSLocalizedDescriptionKey: r.out])
        }
        let whole = String(dev).replacingOccurrences(of: "/dev/", with: "")
        // nós de imagem nascem r-- pro dono; o teste precisa ler/escrever na própria imagem
        for node in ["/dev/\(whole)", "/dev/r\(whole)", "/dev/\(whole)s1", "/dev/r\(whole)s1"] { chmod(node, 0o640 | 0o200) }
        return Attached(wholeDisk: whole)
    }

    static func mount(_ bsd: String) throws -> String {
        let r = try run("/usr/sbin/diskutil", ["mount", bsd])
        guard r.status == 0 else { throw NSError(domain: "DiskImageTool", code: 2, userInfo: [NSLocalizedDescriptionKey: r.out]) }
        let info = try run("/usr/sbin/diskutil", ["info", bsd]).out
        let mp = info.split(separator: "\n").first { $0.contains("Mount Point:") }!
        return mp.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
    }

    static func detach(_ bsd: String) { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", bsd]) }
}
