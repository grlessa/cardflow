import Foundation
import Testing
import OffloadKit
@testable import CardflowApp

/// Tela de gerenciar modelos: duplicar, renomear e excluir, sempre numa pasta temporária.
@MainActor
@Suite struct ManageModelsTests {
    private func model() throws -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cardflow-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = AppModel(presetsDirectory: dir)
        var p = Preset.factoryDefault
        p.id = "batismo"
        p.name = "Batismo"
        _ = try m.presetStore.save(p)
        m.reloadPresets()
        return m
    }

    @Test func duplicarCriaCopiaSemTrocarOModeloEmUso() throws {
        let m = try model()
        m.duplicatePreset("batismo")
        #expect(m.presets.count == 3)
        #expect(m.presets.contains { $0.id != "batismo" && $0.name.contains("Batismo") })
        #expect(m.selectedPresetId == Preset.factoryDefault.id)
    }

    @Test func duplicarDuasVezesNaoRepeteNome() throws {
        let m = try model()
        m.duplicatePreset("batismo")
        m.duplicatePreset("batismo")
        let names = m.presets.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func duplicarPeloPainelUsaACopiaENaoRepeteNome() throws {
        let m = try model()
        m.usePreset("batismo")
        m.duplicateActivePreset()
        m.usePreset("batismo")
        m.duplicateActivePreset()
        let names = m.presets.map(\.name)
        #expect(m.presets.count == 4)
        #expect(Set(names).count == names.count)
        #expect(m.selectedPresetId != "batismo")
    }

    @Test func renomearIgnoraNomeVazioEOModeloDeFabrica() throws {
        let m = try model()
        m.renamePreset("batismo", to: "  Batizado  ")
        #expect(m.presets.first { $0.id == "batismo" }?.name == "Batizado")
        m.renamePreset("batismo", to: "   ")
        #expect(m.presets.first { $0.id == "batismo" }?.name == "Batizado")
        m.renamePreset(Preset.factoryDefault.id, to: "Outro")
        #expect(m.presets.first?.name == Preset.factoryDefault.name)
    }

    @Test func excluirNuncaApagaOModeloDeFabrica() throws {
        let m = try model()
        m.deletePresets([Preset.factoryDefault.id, "batismo"])
        #expect(m.presets.map(\.id) == [Preset.factoryDefault.id])
    }

    @Test func excluirOModeloEmUsoVoltaProDeFabrica() throws {
        let m = try model()
        m.usePreset("batismo")
        #expect(m.selectedPresetId == "batismo")
        m.deletePresets(["batismo"])
        #expect(m.selectedPresetId == Preset.factoryDefault.id)
        #expect(!m.presets.contains { $0.id == "batismo" })
    }

    @Test func receitaDescreveCadaNivel() throws {
        let m = try model()
        let recipe = m.folderRecipe(m.presets[0])
        #expect(recipe.contains("›"))
        #expect(!recipe.contains("{"))
    }
}
