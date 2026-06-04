import Foundation

public struct DiskResolver {
    public typealias Volume = (url: URL, uuid: String?)
    private let volumes: () -> [Volume]

    public init(volumes: @escaping () -> [Volume] = DiskResolver.systemVolumes) {
        self.volumes = volumes
    }

    public static func systemVolumes() -> [Volume] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []
        ) ?? []
        return urls.map { ($0, volumeUUID(at: $0)) }
    }

    public static func volumeUUID(at url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    public func mountPath(forVolumeUUID uuid: String) -> URL? {
        volumes().first { $0.uuid == uuid }?.url
    }

    /// UUID montado tem prioridade; senão o último caminho conhecido, se ainda existir; senão nil.
    public func resolve(_ binding: DiskBinding) -> URL? {
        if let uuid = binding.volumeUUID, let url = mountPath(forVolumeUUID: uuid) { return url }
        // isDirectory: false evita a barra final que o construtor padrão adiciona ao detectar
        // um diretório existente, mantendo o URL idêntico ao caminho originalmente vinculado.
        let path = URL(fileURLWithPath: binding.lastKnownPath, isDirectory: false)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }
}
