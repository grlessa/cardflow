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
        if exclusive {
            // O_NONBLOCK serviu só para não travar esperando O_EXLOCK; limpa depois pra I/O bloqueante.
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let e = errno; Darwin.close(fd); fd = -1; throw BlockDeviceError(operation: "fstat", errno: e)
        }
        let mode = st.st_mode & S_IFMT
        if mode == S_IFCHR || mode == S_IFBLK {
            // Dispositivo de bloco/cru: confere diretamente no descritor aberto tamanho de setor e total
            // de setores (evita confiar cegamente no tamanho informado antes do open).
            let dkiocGetBlockSize: UInt = 0x4004_6418   // _IOR('d', 24, uint32_t)
            let dkiocGetBlockCount: UInt = 0x4008_6419  // _IOR('d', 25, uint64_t)
            var blockSize: UInt32 = 0
            var actualSectors: UInt64 = 0
            guard ioctl(fd, dkiocGetBlockSize, &blockSize) == 0,
                  ioctl(fd, dkiocGetBlockCount, &actualSectors) == 0 else {
                let e = errno; Darwin.close(fd); fd = -1; throw BlockDeviceError(operation: "ioctl", errno: e)
            }
            guard blockSize == 512 else {
                Darwin.close(fd); fd = -1; throw BlockDeviceError(operation: "blockSize", errno: EINVAL)
            }
            if let expected = sectorCount, expected != actualSectors {
                Darwin.close(fd); fd = -1; throw BlockDeviceError(operation: "sectorCount", errno: EINVAL)
            }
            self.sectorCount = actualSectors
        } else if let sectorCount {
            self.sectorCount = sectorCount
        } else {
            self.sectorCount = UInt64(st.st_size) / 512
        }
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
        guard count >= 0, sector <= sectorCount, UInt64(count) <= sectorCount - sector else {
            throw BlockDeviceError(operation: "pread (limites)", errno: EINVAL)
        }
        let total = count * 512
        if total == 0 { return [] }
        var buf = [UInt8](repeating: 0, count: total)
        try buf.withUnsafeMutableBytes { raw in
            var done = 0
            while done < total {
                let n = pread(fd, raw.baseAddress!.advanced(by: done), total - done, off_t(sector * 512) + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw BlockDeviceError(operation: "pread", errno: errno)
                }
                if n == 0 { throw BlockDeviceError(operation: "pread (EOF)", errno: EIO) }
                done += n
            }
        }
        return buf
    }

    public func write(sector: UInt64, _ bytes: [UInt8]) throws {
        guard bytes.count % 512 == 0 else { throw BlockDeviceError(operation: "write (tamanho)", errno: EINVAL) }
        let count = UInt64(bytes.count / 512)
        guard sector <= sectorCount, count <= sectorCount - sector else {
            throw BlockDeviceError(operation: "pwrite (limites)", errno: EINVAL)
        }
        if bytes.isEmpty { return }
        try bytes.withUnsafeBytes { raw in
            var done = 0
            while done < bytes.count {
                let n = pwrite(fd, raw.baseAddress!.advanced(by: done), bytes.count - done, off_t(sector * 512) + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw BlockDeviceError(operation: "pwrite", errno: errno)
                }
                if n == 0 { throw BlockDeviceError(operation: "pwrite (EOF)", errno: EIO) }
                done += n
            }
        }
    }

    public func zero(sector: UInt64, count: UInt64) throws {
        guard sector <= sectorCount, count <= sectorCount - sector else {
            throw BlockDeviceError(operation: "zero (limites)", errno: EINVAL)
        }
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
