import Foundation

/// Implementação pura (sem dependências) do xxHash64.
/// Suporta hashing one-shot e incremental (update em pedaços).
public struct XXHash64 {
    private static let p1: UInt64 = 0x9E3779B185EBCA87
    private static let p2: UInt64 = 0xC2B2AE3D27D4EB4F
    private static let p3: UInt64 = 0x165667B19E3779F9
    private static let p4: UInt64 = 0x85EBCA77C2B2AE63
    private static let p5: UInt64 = 0x27D4EB2F165667C5

    private let seed: UInt64
    private var v1: UInt64
    private var v2: UInt64
    private var v3: UInt64
    private var v4: UInt64
    private var totalLen: UInt64 = 0
    private var buffer = [UInt8](repeating: 0, count: 32)
    private var bufferLen = 0

    public init(seed: UInt64 = 0) {
        self.seed = seed
        self.v1 = seed &+ Self.p1 &+ Self.p2
        self.v2 = seed &+ Self.p2
        self.v3 = seed
        self.v4 = seed &- Self.p1
    }

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }

    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        var a = acc &+ (input &* p2)
        a = rotl(a, 31)
        return a &* p1
    }

    @inline(__always) private static func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        let v = round(0, val)
        var a = acc ^ v
        a = a &* p1 &+ p4
        return a
    }

    @inline(__always) private static func read64(_ b: [UInt8], _ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * k) }
        return v
    }

    @inline(__always) private static func read32(_ b: [UInt8], _ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<4 { v |= UInt64(b[i + k]) << (8 * k) }
        return v
    }

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count > 0 else { return }
        totalLen &+= UInt64(bytes.count)
        var input = Array(bytes)
        var index = 0

        // Completa o buffer pendente até 32 e processa.
        if bufferLen > 0 {
            let need = 32 - bufferLen
            if input.count < need {
                for k in 0..<input.count { buffer[bufferLen + k] = input[k] }
                bufferLen += input.count
                return
            }
            for k in 0..<need { buffer[bufferLen + k] = input[k] }
            v1 = Self.round(v1, Self.read64(buffer, 0))
            v2 = Self.round(v2, Self.read64(buffer, 8))
            v3 = Self.round(v3, Self.read64(buffer, 16))
            v4 = Self.round(v4, Self.read64(buffer, 24))
            index = need
            bufferLen = 0
        }

        // Processa blocos completos de 32 bytes direto do input.
        while index + 32 <= input.count {
            v1 = Self.round(v1, Self.read64(input, index))
            v2 = Self.round(v2, Self.read64(input, index + 8))
            v3 = Self.round(v3, Self.read64(input, index + 16))
            v4 = Self.round(v4, Self.read64(input, index + 24))
            index += 32
        }

        // Guarda o resto.
        let remaining = input.count - index
        if remaining > 0 {
            for k in 0..<remaining { buffer[k] = input[index + k] }
            bufferLen = remaining
        }
        input.removeAll(keepingCapacity: false)
    }

    public func finalize() -> UInt64 {
        var h: UInt64
        if totalLen >= 32 {
            h = Self.rotl(v1, 1) &+ Self.rotl(v2, 7) &+ Self.rotl(v3, 12) &+ Self.rotl(v4, 18)
            h = Self.mergeRound(h, v1)
            h = Self.mergeRound(h, v2)
            h = Self.mergeRound(h, v3)
            h = Self.mergeRound(h, v4)
        } else {
            h = seed &+ Self.p5
        }
        h &+= totalLen

        var i = 0
        while i + 8 <= bufferLen {
            let k1 = Self.round(0, Self.read64(buffer, i))
            h ^= k1
            h = Self.rotl(h, 27) &* Self.p1 &+ Self.p4
            i += 8
        }
        if i + 4 <= bufferLen {
            h ^= Self.read32(buffer, i) &* Self.p1
            h = Self.rotl(h, 23) &* Self.p2 &+ Self.p3
            i += 4
        }
        while i < bufferLen {
            h ^= UInt64(buffer[i]) &* Self.p5
            h = Self.rotl(h, 11) &* Self.p1
            i += 1
        }

        h ^= h >> 33
        h &*= Self.p2
        h ^= h >> 29
        h &*= Self.p3
        h ^= h >> 32
        return h
    }

    // MARK: - Conveniências

    public static func hash(_ data: Data, seed: UInt64 = 0) -> UInt64 {
        var hasher = XXHash64(seed: seed)
        data.withUnsafeBytes { hasher.update($0) }
        return hasher.finalize()
    }

    /// Hash de um arquivo lendo em blocos (não carrega tudo na memória).
    public static func hash(fileAt url: URL, seed: UInt64 = 0, chunkSize: Int = 1 << 22) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = XXHash64(seed: seed)
        var done = false
        while !done {
            try autoreleasepool {
                guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { done = true; return }
                data.withUnsafeBytes { hasher.update($0) }
            }
        }
        return hasher.finalize()
    }
}
