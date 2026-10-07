import Foundation

public protocol BlockDevice: AnyObject {
    var sectorCount: UInt64 { get }
    func read(sector: UInt64, count: Int) throws -> [UInt8]
    func write(sector: UInt64, _ bytes: [UInt8]) throws
    func zero(sector: UInt64, count: UInt64) throws
    func synchronize() throws
}

public struct BlockDeviceError: Error, Equatable, Sendable {
    public let operation: String
    public let errno: Int32
    public init(operation: String, errno: Int32) { self.operation = operation; self.errno = errno }
}

/// pread/pwrite em setores de 512 bytes. Serve pra arquivo comum, imagem de disco e `/dev/rdiskN`
/// (dispositivo cru exige offset e tamanho múltiplos de 512, garantido aqui).
public final class FileBlockDevice: BlockDevice {
    private var fd: Int32
    public let sectorCount: UInt64

    public init(path: String, sectorCount: UInt64? = nil, exclusive: Bool = false) throws {
        fd = open(path, O_RDWR | (exclusive ? O_EXLOCK | O_NONBLOCK : 0))
        guard fd >= 0 else { throw BlockDeviceError(operation: "open \(path)", errno: errno) }
        if let sectorCount {
            self.sectorCount = sectorCount
        } else {
            var st = stat()
            guard fstat(fd, &st) == 0 else {
                let e = errno; Darwin.close(fd); throw BlockDeviceError(operation: "fstat", errno: e)
            }
            self.sectorCount = UInt64(st.st_size) / 512
        }
    }

    /// Usa um descritor já aberto por outro caminho (ex.: o authopen do sistema). Passa a ser dono dele.
    public init(fd: Int32, sectorCount: UInt64) {
        self.fd = fd
        self.sectorCount = sectorCount
    }

    public static func createSparse(at path: String, sectors: UInt64) throws -> FileBlockDevice {
        let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw BlockDeviceError(operation: "create", errno: errno) }
        guard ftruncate(fd, off_t(sectors * 512)) == 0 else {
            let e = errno; Darwin.close(fd); throw BlockDeviceError(operation: "ftruncate", errno: e)
        }
        Darwin.close(fd)
        return try FileBlockDevice(path: path)
    }

    deinit { close() }
    public func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }

    public func read(sector: UInt64, count: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count * 512)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(sector * 512)) }
        guard n == buf.count else { throw BlockDeviceError(operation: "pread", errno: errno) }
        return buf
    }

    public func write(sector: UInt64, _ bytes: [UInt8]) throws {
        guard bytes.count % 512 == 0 else { throw BlockDeviceError(operation: "write (tamanho)", errno: EINVAL) }
        let n = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(sector * 512)) }
        guard n == bytes.count else { throw BlockDeviceError(operation: "pwrite", errno: errno) }
    }

    public func zero(sector: UInt64, count: UInt64) throws {
        let chunk: UInt64 = 2048   // 1 MiB por escrita
        let zeros = [UInt8](repeating: 0, count: Int(chunk) * 512)
        var s = sector, left = count
        while left > 0 {
            let n = min(chunk, left)
            try write(sector: s, n == chunk ? zeros : [UInt8](repeating: 0, count: Int(n) * 512))
            s += n; left -= n
        }
    }

    public func synchronize() throws {
        guard fsync(fd) == 0 else { throw BlockDeviceError(operation: "fsync", errno: errno) }
    }
}
