import Foundation

public protocol ActivityKeeping {
    func begin(reason: String) -> NSObjectProtocol
    func end(_ token: NSObjectProtocol)
}

/// Real: impede App Nap e sleep do sistema durante o offload.
public struct SystemActivityKeeper: ActivityKeeping {
    public init() {}
    public func begin(reason: String) -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
    }
    public func end(_ token: NSObjectProtocol) {
        ProcessInfo.processInfo.endActivity(token)
    }
}

/// Para testes — não toca no sistema.
public struct NoopActivityKeeper: ActivityKeeping {
    public init() {}
    public func begin(reason: String) -> NSObjectProtocol { NSObject() }
    public func end(_ token: NSObjectProtocol) {}
}
