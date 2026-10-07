import Testing
import Foundation
import ImageIO
import AVFoundation
@testable import OffloadKit

@Suite struct CameraMetadataTests {

    // MARK: compose (função pura)

    @Test func composeJuntaMarcaEModelo() {
        #expect(CameraMetadata.compose(make: "SONY", model: "ILCE-7M4") == "SONY ILCE-7M4")
    }

    @Test func composeNaoDuplicaMarcaJaNoModelo() {
        #expect(CameraMetadata.compose(make: "Canon", model: "Canon EOS R5") == "Canon EOS R5")
        #expect(CameraMetadata.compose(make: "NIKON CORPORATION", model: "NIKON Z 9") == "NIKON Z 9")
    }

    @Test func composeUsaOQueTiver() {
        #expect(CameraMetadata.compose(make: nil, model: "iPhone 15 Pro") == "iPhone 15 Pro")
        #expect(CameraMetadata.compose(make: "DJI", model: nil) == "DJI")
    }

    @Test func composeVazioOuSoEspacoEhNil() {
        #expect(CameraMetadata.compose(make: nil, model: nil) == nil)
        #expect(CameraMetadata.compose(make: "  ", model: " ") == nil)
    }

    @Test func composeApara() {
        #expect(CameraMetadata.compose(make: " SONY ", model: " ILCE-7M4 ") == "SONY ILCE-7M4")
    }

    // MARK: foto (round-trip: grava EXIF com ImageIO, lê de volta)

    private func writeJPEG(make: String?, model: String?, to url: URL) throws {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        var tiff: [CFString: Any] = [:]
        if let make { tiff[kCGImagePropertyTIFFMake] = make }
        if let model { tiff[kCGImagePropertyTIFFModel] = model }
        let props: [CFString: Any] = tiff.isEmpty ? [:] : [kCGImagePropertyTIFFDictionary: tiff]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func lePhotoCameraModelDoExif() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("DSC00001.JPG")
        try writeJPEG(make: "SONY", model: "ILCE-7M4", to: url)
        #expect(CameraMetadata.photoCameraModel(at: url) == "SONY ILCE-7M4")
    }

    @Test func fotoSemExifDevolveNil() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("plain.JPG")
        try writeJPEG(make: nil, model: nil, to: url)
        #expect(CameraMetadata.photoCameraModel(at: url) == nil)
    }

    @Test func firstCameraModelPegaOPrimeiroDetectavel() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 1º sem EXIF, 2º com EXIF → deve pegar o 2º
        let u1 = dir.appendingPathComponent("a.JPG"); try writeJPEG(make: nil, model: nil, to: u1)
        let u2 = dir.appendingPathComponent("b.JPG"); try writeJPEG(make: "Canon", model: "Canon EOS R5", to: u2)
        let files = [u1, u2].map {
            MediaFile(sourceURL: $0, relPath: $0.lastPathComponent, size: 1, type: .photo,
                      captureDate: Date(timeIntervalSince1970: 0))
        }
        let found = await CameraMetadata.firstCameraModel(in: files)
        #expect(found == "Canon EOS R5")
    }
}

// MARK: vídeo (round-trip: grava um .mov curto com marca/modelo no metadado QuickTime, lê de volta)

@Suite struct CameraMetadataVideoTests {
    /// Grava 3 quadros H.264 16x16 com `com.apple.quicktime.make/model` (o que iPhone, DJI e várias
    /// câmeras escrevem), sem nada quando make/model forem nil.
    private func writeMOV(make: String?, model: String?, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = [(AVMetadataIdentifier.quickTimeMetadataMake, make),
                           (AVMetadataIdentifier.quickTimeMetadataModel, model)].compactMap { id, value in
            guard let value else { return nil }
            let item = AVMutableMetadataItem()
            item.identifier = id; item.value = value as NSString; item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<3 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            #expect(adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func leCameraDoMetadadoDoVideo() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("C0001.MOV")
        try await writeMOV(make: "DJI", model: "Osmo Pocket 3", to: url)
        #expect(await CameraMetadata.cameraModel(at: url, type: .video) == "DJI Osmo Pocket 3")
    }

    @Test func videoSemMetadadoDeCameraDevolveNil() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("C0002.MOV")
        try await writeMOV(make: nil, model: nil, to: url)
        #expect(await CameraMetadata.cameraModel(at: url, type: .video) == nil)
    }

    @Test func videoIlegivelDevolveNilSemTravar() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("C0003.MP4")
        try Data("nao e um video".utf8).write(to: url)
        #expect(await CameraMetadata.cameraModel(at: url, type: .video) == nil)
    }
}

@Suite struct CameraDefaultNameTests {
    @Test func primeiraLetraLivre() {
        #expect(CameraMetadata.defaultName(avoiding: []) == "CAM A")
        #expect(CameraMetadata.defaultName(avoiding: ["CAM A"]) == "CAM B")
        #expect(CameraMetadata.defaultName(avoiding: ["CAM A", "CAM C"]) == "CAM B")
    }
}

@Suite struct CameraShortNameTests {
    @Test(arguments: [
        ("SONY ILME-FX30", "FX30"), ("SONY ILME-FX3", "FX3"), ("SONY ILCE-7SM3", "A7S III"), ("SONY ILCE-7M4", "A7 IV"),
        ("SONY ILCE-1", "A1"), ("SONY ILCE-6700", "A6700"), ("SONY DSC-RX100M7", "RX100 VII"), ("SONY ILCE-7RM5", "A7R V"),
        ("Panasonic DC-S5M2", "S5II"), ("Panasonic DC-S5M2X", "S5IIX"), ("Panasonic DC-GH6", "GH6"), ("Panasonic DC-S1H", "S1H"),
        ("Canon EOS R5", "R5"), ("Canon EOS R5 C", "R5 C"), ("Canon EOS 5D Mark IV", "5D Mark IV"), ("Canon EOS C70", "C70"),
        ("NIKON Z 6_2", "Z6 II"), ("NIKON Z 8", "Z8"), ("NIKON D850", "D850"),
        ("FUJIFILM X-T5", "X-T5"), ("Apple iPhone 15 Pro", "iPhone 15 Pro"), ("GoPro HERO12 Black", "GoPro HERO12 Black"),
        ("DJI FC3582", "DJI FC3582"),
    ])
    func encurta(_ full: String, _ short: String) {
        #expect(CameraMetadata.shortName(full) == short)
    }
}

@Suite struct CameraSidecarTests {
    @Test func leDeviceDoXMLDaSony() {
        let xml = #"<NonRealTimeMeta><Device manufacturer="Sony" modelName="ILME-FX30" serialNo="01049843"/><Lens modelName="Viltrox 9mm F2.8 E"/></NonRealTimeMeta>"#
        #expect(CameraMetadata.deviceModel(inXML: xml) == "Sony ILME-FX30")
        #expect(CameraMetadata.shortName(CameraMetadata.deviceModel(inXML: xml)!) == "FX30")
    }

    @Test func atributosEmOutraOrdem() {
        #expect(CameraMetadata.deviceModel(inXML: #"<Device modelName="DC-S5M2" manufacturer="Panasonic"/>"#) == "Panasonic DC-S5M2")
        #expect(CameraMetadata.deviceModel(inXML: "<Clip/>") == nil)
    }

    @Test func achaOXMLAoLadoDoClipe() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cf-xml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("<Device manufacturer=\"Sony\" modelName=\"ILME-FX3\"/>".utf8).write(to: dir.appendingPathComponent("C0001M01.XML"))
        #expect(CameraMetadata.sidecarCameraModel(for: dir.appendingPathComponent("C0001.MP4")) == "Sony ILME-FX3")
    }
}
