import Testing
import Foundation
@testable import OffloadKit

@Suite struct PreservePlannerTests {
    /// Helper: monta um MediaFile só com o que o planner usa (relPath + type).
    private func mf(_ rel: String, _ type: FileType) -> MediaFile {
        MediaFile(sourceURL: URL(fileURLWithPath: "/c/\(rel)"), relPath: rel, size: 1, type: type,
                  captureDate: Date(timeIntervalSince1970: 0))
    }
    private func preserved(_ files: [MediaFile]) -> Set<String> {
        Set(PreservePlanner.plan(files).filter { $0.preserve }.map(\.relPath))
    }

    @Test func redContainerPreservaArvoreEPlanoFicaFora()  {
        let files = [
            mf("DCIM/100MSDCF/DSC0001.JPG", .photo),                 // plano
            mf("A001_R1.RDM/A001_C001.RDC/A001_C001_001.R3D", .cinema),
            mf("A001_R1.RDM/A001_C001.RDC/A001_C001_002.R3D", .cinema),
            mf("A001_R1.RDM/A001_C001.RDC/A001_C001.RMD", .unknown), // irmão metadata
            mf("A001_R1.RDM/A001_C001.RDC/A001_C001.mov", .video),  // irmão referência
        ]
        let p = preserved(files)
        #expect(!p.contains("DCIM/100MSDCF/DSC0001.JPG"))           // DCIM continua plano
        #expect(p.contains("A001_R1.RDM/A001_C001.RDC/A001_C001_001.R3D"))
        #expect(p.contains("A001_R1.RDM/A001_C001.RDC/A001_C001.RMD"))  // irmão vem junto
        #expect(p.contains("A001_R1.RDM/A001_C001.RDC/A001_C001.mov")) // irmão vem junto
    }

    @Test func p2ContentsPreservaIrmaosVideoAudioClipIcon() {
        let files = [
            mf("CONTENTS/VIDEO/0001AB.MXF", .cinema),
            mf("CONTENTS/AUDIO/0001AB.MXF", .cinema),
            mf("CONTENTS/CLIP/0001AB.XML", .sidecar),  // metadata — type sidecar
            mf("CONTENTS/ICON/0001AB.BMP", .junk),     // thumbnail — type junk
            mf("LASTCLIP.TXT", .unknown),              // solto na raiz, não-cinema
        ]
        let p = preserved(files)
        #expect(p.contains("CONTENTS/VIDEO/0001AB.MXF"))
        #expect(p.contains("CONTENTS/AUDIO/0001AB.MXF"))
        #expect(p.contains("CONTENTS/CLIP/0001AB.XML"))   // sidecar preservado (ignora o type)
        #expect(p.contains("CONTENTS/ICON/0001AB.BMP"))   // junk preservado (ignora o type)
        #expect(!p.contains("LASTCLIP.TXT"))              // solto não-cinema fica fora
    }

    @Test func brawSoltoNaRaizGrudaSidecar() {
        let files = [
            mf("A001.braw", .cinema),
            mf("A001.sidecar", .unknown),   // mesmo nome-base → cola
            mf("B002.braw", .cinema),
            mf("avulso.txt", .unknown),     // nome-base diferente → fica fora
        ]
        let p = preserved(files)
        #expect(p.contains("A001.braw"))
        #expect(p.contains("A001.sidecar"))   // colado pelo nome-base
        #expect(p.contains("B002.braw"))
        #expect(!p.contains("avulso.txt"))
    }

    @Test func todoArquivoCinemaSempreFicaPreservado() {
        // garante a invariante: nenhum .cinema escapa do preserve (senão seria dropado na seleção)
        let files = [mf("X/Y/Z/lone.mxf", .cinema), mf("lone2.r3d", .cinema)]
        let p = preserved(files)
        #expect(p.contains("X/Y/Z/lone.mxf"))
        #expect(p.contains("lone2.r3d"))
    }

    @Test func looseFotoDeNomeCoincidenteNaoEhAbsorvidaPeloBundle() {
        // A001.braw (cinema solto) + A001.jpg (foto real, stem coincidente) na raiz: a foto NÃO pode
        // virar preserve — senão num offload só-foto seria DROPADA (isSelected exclui preservados).
        let files = [
            mf("A001.braw", .cinema),
            mf("A001.jpg", .photo),
            mf("A001.sidecar", .unknown),   // metadata → gruda
        ]
        let p = preserved(files)
        #expect(p.contains("A001.braw"))
        #expect(p.contains("A001.sidecar"))    // companheiro de metadata gruda
        #expect(!p.contains("A001.jpg"))       // foto real NÃO é absorvida → vai pro pipeline plano
    }

    @Test func systemJunkDentroDoBundleNaoPreserva() {
        // .DS_Store herda o preserve root (1º segmento CONTENTS) — precisa de guarda explícita,
        // senão a poluição do macOS é copiada verbatim pro destino.
        let files = [
            mf("CONTENTS/VIDEO/x.MXF", .cinema),
            mf("CONTENTS/.DS_Store", .junk),
        ]
        let p = preserved(files)
        #expect(p.contains("CONTENTS/VIDEO/x.MXF"))
        #expect(!p.contains("CONTENTS/.DS_Store"))   // system junk fora, mesmo no preserve root
    }

    @Test func bundleKeyIsTopSegmentOrStem() {
        #expect(PreservePlanner.bundleKey("A001.RDM/c.RDC/x.R3D") == "A001.RDM")
        #expect(PreservePlanner.bundleKey("CONTENTS/VIDEO/x.MXF") == "CONTENTS")
        #expect(PreservePlanner.bundleKey("clip.braw") == "clip")
        #expect(PreservePlanner.bundleKey("clip.sidecar") == "clip")
    }

    @Test func bundleCountContaPacotesNaoArquivos() {
        let planned = PreservePlanner.plan([
            mf("A001.RDM/c.RDC/a_001.R3D", .cinema),
            mf("A001.RDM/c.RDC/a_002.R3D", .cinema),  // mesmo bundle (A001.RDM)
            mf("CONTENTS/VIDEO/x.MXF", .cinema),      // bundle CONTENTS
            mf("loose.braw", .cinema),                // bundle loose "loose"
            mf("loose.sidecar", .unknown),            // mesmo bundle loose
            mf("DCIM/100/DSC.JPG", .photo),           // plano, não conta
        ])
        #expect(PreservePlanner.bundleCount(planned) == 3)  // A001.RDM + CONTENTS + loose
    }
}
