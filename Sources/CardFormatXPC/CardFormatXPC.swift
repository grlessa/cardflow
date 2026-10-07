import Foundation
import CardFormatKit

public enum FormatStep: Int, Codable, Sendable, CaseIterable {
    case validating, unmounting, partitioning, writingFileSystem, verifying, remounting
}

public struct FormatRequest: Codable, Equatable, Sendable {
    public var bsdName: String               // disco INTEIRO, ex.: "disk4"
    public var expectedTotalBytes: UInt64
    public var expectedVolumeUUID: String?
    public var label: String
    public init(bsdName: String, expectedTotalBytes: UInt64, expectedVolumeUUID: String?, label: String) {
        self.bsdName = bsdName; self.expectedTotalBytes = expectedTotalBytes
        self.expectedVolumeUUID = expectedVolumeUUID; self.label = label
    }
}

public enum FormatFailure: String, Codable, Sendable {
    case busy, deviceRejected, cardChanged, unmountFailed, planRejected, writeFailed, verifyFailed, fsckFailed, internalError
    case diskAccessDenied   // o macOS negou o disco cru: o ajudante precisa de Acesso Total ao Disco
}

public struct FormatResponse: Codable, Equatable, Sendable {
    public var failure: FormatFailure?
    public var detail: String?
    public var plan: FormatPlan?
    public var ok: Bool { failure == nil }
    public init(failure: FormatFailure?, detail: String?, plan: FormatPlan?) {
        self.failure = failure; self.detail = detail; self.plan = plan
    }
}

@objc public protocol CardFormatProgressProtocol {
    func step(_ raw: Int)
}

@objc public protocol CardFormatServiceProtocol {
    func format(_ request: Data, progress: CardFormatProgressProtocol, reply: @escaping (Data) -> Void)
    func ping(reply: @escaping (String) -> Void)
    /// O ajudante tem Acesso Total ao Disco? (sem ele, o leitor de SD embutido recusa a formatação)
    func checkDiskAccess(reply: @escaping (Bool) -> Void)
}

/// Nomes e requisitos de assinatura dos dois lados. O helper só aceita o Cardflow do mesmo time; o app só
/// fala com o helper do mesmo time.
public enum CardFormatXPC {
    public static let machServiceName = "com.cardflow.app.formathelper"
    public static let plistName = "com.cardflow.app.formathelper.plist"
    public static let teamID = "NAS37P6Q53"
    public static let clientRequirement =
        "identifier \"com.cardflow.app\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    public static let helperRequirement =
        "identifier \"com.cardflow.app.formathelper\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""

    public static func serviceInterface() -> NSXPCInterface {
        let i = NSXPCInterface(with: CardFormatServiceProtocol.self)
        i.setInterface(progressInterface(),
                       for: #selector(CardFormatServiceProtocol.format(_:progress:reply:)), argumentIndex: 1, ofReply: false)
        return i
    }
    public static func progressInterface() -> NSXPCInterface { NSXPCInterface(with: CardFormatProgressProtocol.self) }
}
