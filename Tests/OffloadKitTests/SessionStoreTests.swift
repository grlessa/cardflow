import Testing
import Foundation
@testable import OffloadKit

@Suite struct SessionStoreTests {
    @Test func loadReturnsNilWhenAbsent() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/session.json")
        #expect(SessionStore(fileURL: url).load() == nil)
    }

    @Test func saveThenLoadRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("session.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(fileURL: url)
        let session = Session(
            activePresetId: "meu-evento",
            destinationBindings: [
                "Cópia": .init(volumeUUID: "ABCD-1234", lastKnownPath: "/Volumes/SSD_Cam01"),
                "Backup": .init(volumeUUID: nil, lastKnownPath: "/Volumes/HD"),
            ],
            sessionValues: ["camera": "Cam01", "operador": "Joao"],
            lastMediaChoice: "both"
        )
        try store.save(session)
        #expect(store.load() == session)
    }

    @Test func appSessionFileHasExpectedSuffix() {
        #expect(SessionStore.appSessionFile().path.hasSuffix("Cardflow/session.json"))
    }

    @Test func diskBindingResolvesByUUIDThenPath() {
        func vol(_ name: String, _ uuid: String?, _ path: String) -> ExternalVolume {
            ExternalVolume(url: URL(fileURLWithPath: path), name: name, isRemovable: true,
                           isInternal: false, totalBytes: nil, physicalDeviceID: nil, volumeUUID: uuid)
        }
        let vols = [vol("HD", "UUID-A", "/Volumes/HD"), vol("SSD", "UUID-B", "/Volumes/SSD"), vol("NET", nil, "/Volumes/NET")]
        // casa por UUID mesmo se o path mudou
        #expect(DiskBinding(volumeUUID: "UUID-B", lastKnownPath: "/Volumes/outro").resolve(in: vols)?.path == "/Volumes/SSD")
        // sem UUID salvo: casa por path SÓ se o volume nesse path também não tem UUID
        #expect(DiskBinding(volumeUUID: nil, lastKnownPath: "/Volumes/NET").resolve(in: vols)?.path == "/Volumes/NET")
        // sem UUID salvo, mas o volume nesse path TEM uuid (disco diferente reusou o mount) → NÃO casa
        #expect(DiskBinding(volumeUUID: nil, lastKnownPath: "/Volumes/HD").resolve(in: vols) == nil)
        // UUID vazio = ausente → mesma regra do path
        #expect(DiskBinding(volumeUUID: "", lastKnownPath: "/Volumes/NET").resolve(in: vols)?.path == "/Volumes/NET")
        // não montado → nil
        #expect(DiskBinding(volumeUUID: "UUID-Z", lastKnownPath: "/Volumes/sumiu").resolve(in: vols) == nil)
    }

    // Atalho interno (Mesa/Documentos) não é volume montado: volumeUUID nil → persiste casando por caminho.
    @Test func diskBindingResolvesInternalShortcutByPath() {
        let docs = ExternalVolume(url: URL(fileURLWithPath: "/Users/x/Documents"), name: "Documentos",
                                  isRemovable: false, isInternal: true, physicalDeviceID: "disk1",
                                  volumeUUID: nil, isInternalShortcut: true)
        #expect(DiskBinding(volumeUUID: nil, lastKnownPath: "/Users/x/Documents").resolve(in: [docs])?.path == "/Users/x/Documents")
        #expect(DiskBinding(volumeUUID: nil, lastKnownPath: "/Users/x/Documents").resolve(in: []) == nil)   // sem crash
    }
}
