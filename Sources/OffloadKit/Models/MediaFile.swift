import Foundation

public struct MediaFile: Equatable, Sendable {
    public var sourceURL: URL
    public var relPath: String   // relativo à raiz do cartão, com "/" como separador
    public var size: Int64
    public var type: FileType
    public var captureDate: Date
    public var preserve: Bool    // true → copiado verbatim (cinema), sem renomear/achatar

    public init(sourceURL: URL, relPath: String, size: Int64, type: FileType,
                captureDate: Date, preserve: Bool = false) {
        self.sourceURL = sourceURL; self.relPath = relPath; self.size = size
        self.type = type; self.captureDate = captureDate; self.preserve = preserve
    }
}
