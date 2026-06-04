import Foundation

struct FakeCardCLI {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-card-" + UUID().uuidString)
        let fm = FileManager.default
        func write(_ rel: String, _ n: Int) throws {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((0..<n).map { UInt8(($0 + rel.count) & 0xFF) }).write(to: url)
        }
        try write("DCIM/100MSDCF/DSC00001.JPG", 1500)
        try write("PRIVATE/M4ROOT/CLIP/C0001.MP4", 3000)
        try write("MISC/leia.txt", 40)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
