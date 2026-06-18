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
        ("AUDIO.WAV", FileType.audio), // áudio é nativo: reconhecido independente do preset
    ])
    func classifies(fileName: String, expected: FileType) {
        #expect(classifier.classify(fileName: fileName) == expected)
    }

    @Test func audioIsNativeMesmoComPresetSemAudio() {
        // sampleConferencia tem audioExtensions vazio; áudio comum ainda é reconhecido (nativo, como cinema).
        let c = FileClassifier(preset: .sampleConferencia)
        for ext in ["wav", "WAV", "w64", "rf64", "caf", "aif", "aiff", "aifc", "flac",
                    "m4a", "mp3", "aac", "ogg", "opus", "wma", "dsf", "dff", "bwf", "wave"] {
            #expect(c.classify(fileName: "REC001.\(ext)") == .audio, "esperava .audio para .\(ext)")
        }
    }

    @Test func extensoesDoPresetSaoIgnoradas() {
        // O APP define as extensões nativamente; o que o preset listar NÃO conta. Migração: modelo
        // antigo com extensões salvas não afeta o reconhecimento novo.
        var preset = Preset.sampleConferencia
        preset.audioExtensions = ["zzz"]
        preset.photoExtensions = ["qqq"]
        let c = FileClassifier(preset: preset)
        #expect(c.classify(fileName: "WEIRD.ZZZ") == .unknown)
        #expect(c.classify(fileName: "WEIRD.QQQ") == .unknown)
        // o nativo continua valendo mesmo que o preset não liste
        #expect(c.classify(fileName: "REC.WAV") == .audio)
    }

    @Test func sidecarEhNativo() {
        // sidecar reconhecido nativamente (xml/thm/xmp/cube/aae), independente do preset.
        var preset = Preset.sampleConferencia
        preset.sidecarExtensions = []
        let c = FileClassifier(preset: preset)
        for ext in ["xml", "thm", "xmp", "cube", "aae"] {
            #expect(c.classify(fileName: "FILE.\(ext)") == .sidecar, "esperava .sidecar para .\(ext)")
        }
    }

    @Test func fotoEVideoTambemSaoNativos() {
        // sampleConferencia NÃO lista tiff/png/x3f (foto) nem mkv/m4v/mts (vídeo); o nativo reconhece.
        let c = FileClassifier(preset: .sampleConferencia)
        for ext in ["tif", "tiff", "png", "x3f", "pef", "webp"] {
            #expect(c.classify(fileName: "IMG.\(ext)") == .photo, "esperava .photo para .\(ext)")
        }
        for ext in ["mkv", "m4v", "webm", "mts", "m2ts"] {
            #expect(c.classify(fileName: "CLIP.\(ext)") == .video, "esperava .video para .\(ext)")
        }
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
