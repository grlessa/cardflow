import Foundation

enum Fixture {
    static func bytes(_ name: String) -> [UInt8] {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        return [UInt8](try! Data(contentsOf: url))
    }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o+1]) << 8 | UInt32(b[o+2]) << 16 | UInt32(b[o+3]) << 24
    }
}
