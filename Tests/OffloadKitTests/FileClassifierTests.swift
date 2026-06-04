import Testing
@testable import OffloadKit

@Suite struct FileClassifierTests {
    let classifier = FileClassifier(preset: .sampleConferencia)

    @Test(arguments: [
        ("DSC00001.JPG", FileType.photo),
        ("DSC00001.arw", FileType.photo),
        ("C0001.MP4", FileType.video),
        ("C0001.mov", FileType.video),
        ("C0001M01.XML", FileType.sidecar),
        ("C0001.THM", FileType.sidecar),
        (".DS_Store", FileType.junk),
        ("Thumbs.db", FileType.junk),
        ("notas.txt", FileType.unknown),
        ("AUDIO.WAV", FileType.unknown), // áudio desligado por padrão no preset de exemplo
    ])
    func classifies(fileName: String, expected: FileType) {
        #expect(classifier.classify(fileName: fileName) == expected)
    }

    @Test func audioActivatesWhenPresetListsIt() {
        var preset = Preset.sampleConferencia
        preset.audioExtensions = ["wav", "mp3"]
        let c = FileClassifier(preset: preset)
        #expect(c.classify(fileName: "REC001.WAV") == .audio)
    }

    /// Cobertura ampliada (preset de fábrica): vídeo flat de camcorder + RAW modernos de foto.
    @Test(arguments: [
        ("CLIP.MTS", FileType.video),       // AVCHD
        ("STREAM.m2ts", FileType.video),    // AVCHD
        ("ANTIGO.AVI", FileType.video),
        ("PIC.HIF", FileType.photo),        // Nikon HEIF
        ("LEICA.RWL", FileType.photo),      // L-Mount/Leica
        ("GOPRO.GPR", FileType.photo),
        ("SCAN.TIFF", FileType.photo),
        ("REC001.WAV", FileType.audio),     // áudio agora reconhecido por padrão
        ("VOZ.MP3", FileType.audio),
        ("ZOOM.FLAC", FileType.audio),
        ("MEMO.M4A", FileType.audio),
    ])
    func classificaNovasExtensoesDoPadrao(fileName: String, expected: FileType) {
        let c = FileClassifier(preset: .factoryDefault)
        #expect(c.classify(fileName: fileName) == expected)
    }

    /// Thumbnail de vídeo (.jpg de capa) NÃO pode contar como foto — vira lixo.
    @Test func rebaixaThumbnailDeVideoAJunkSemDroparFotoReal() {
        let c = FileClassifier(preset: .factoryDefault)
        // Sony THMBNL: pasta de thumbnail → lixo (independe do tamanho)
        #expect(c.classify(relPath: "PRIVATE/M4ROOT/THMBNL/LF_4591T01.JPG", size: 89_000) == .junk)
        // AVCHD AVCHDTN e Panasonic P2 CONTENTS/ICON: pastas só de thumbnail → lixo
        #expect(c.classify(relPath: "PRIVATE/AVCHD/AVCHDTN/THUMB.TDT", size: 200_000) == .junk)
        #expect(c.classify(relPath: "CONTENTS/ICON/0001AB.BMP", size: 30_000) == .junk)
        // "TableOfContents/icon/..." NÃO é a pasta P2 (match por componente, não substring) → não dropa
        #expect(c.classify(relPath: "TableOfContents/icon/foto.JPG", size: 30_000) == .photo)
        // REGRESSÃO (dataloss): foto pequena solta na raiz / pasta do usuário NÃO some
        #expect(c.classify(relPath: "foto.jpg", size: 70_000) == .photo)
        #expect(c.classify(relPath: "Selecionadas/foto.jpg", size: 200_000) == .photo)
        #expect(c.classify(relPath: "PRIVATE/X/cover.JPG", size: 70_000) == .photo)
        // foto REAL no DCIM NUNCA é rebaixada, mesmo se pequena
        #expect(c.classify(relPath: "DCIM/100MSDCF/DSC00001.JPG", size: 80_000) == .photo)
        // foto/raw real grande no DCIM → foto
        #expect(c.classify(relPath: "DCIM/100MSDCF/DSC00001.JPG", size: 11_000_000) == .photo)
        #expect(c.classify(relPath: "DCIM/100MSDCF/DSC00001.ARW", size: 25_000_000) == .photo)
        // vídeo continua vídeo (não é foto, regra de thumbnail nem se aplica)
        #expect(c.classify(relPath: "PRIVATE/M4ROOT/CLIP/C0001.MP4", size: 500_000_000) == .video)
    }

    @Test func classificaExtensoesDeCinemaComoCinema() {
        let c = FileClassifier(preset: .sampleConferencia)
        for ext in ["r3d", "braw", "crm", "ari", "arx", "mxf", "R3D", "MXF"] {
            #expect(c.classify(fileName: "CLIP001.\(ext)") == .cinema, "esperava .cinema para .\(ext)")
        }
        // não-cinema continua como antes
        #expect(c.classify(fileName: "DSC0001.JPG") == .photo)
        #expect(c.classify(fileName: "C0001.MP4") == .video)
    }
}
