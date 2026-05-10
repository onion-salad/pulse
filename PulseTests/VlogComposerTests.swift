import AVFoundation
import XCTest
@testable import Pulse

final class VlogComposerTests: XCTestCase {
    private static let fixtureSize = CGSize(width: 640, height: 480)

    func testPreviewPlayerItemDoesNotUseCoreAnimationTool() async throws {
        let movieURL = try await Self.makeMovieFixture()
        let moment = CaptureMoment(
            id: UUID(),
            scheduledAt: Date(timeIntervalSince1970: 0),
            clipPath: movieURL.path,
            status: .captured,
            kind: .free,
            customText: nil,
            retakeCount: 0,
            capturedAt: Date(timeIntervalSince1970: 3_600)
        )

        let item = try await VlogComposer().makePlayerItem(moments: [moment], musicID: nil)

        XCTAssertNotNil(item.videoComposition)
        XCTAssertNil(item.videoComposition?.animationTool)
    }

    func testApplyVlogLookExportsFilteredClip() async throws {
        let movieURL = try await Self.makeMovieFixture()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-filtered-\(UUID().uuidString).mov")

        let exportedURL = try await VideoTrimmer().applyVlogLook(
            inputURL: movieURL,
            outputURL: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: exportedURL.path)
        XCTAssertGreaterThan(attributes[.size] as? UInt64 ?? 0, 0)
    }

    private static func makeMovieFixture() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-fixture-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(fixtureSize.width),
                AVVideoHeightKey: Int(fixtureSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 1_000_000
                ]
            ]
        )
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(fixtureSize.width),
                kCVPixelBufferHeightKey as String: Int(fixtureSize.height)
            ]
        )

        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let buffer = try makeBlackPixelBuffer()
            let time = CMTime(value: CMTimeValue(frame), timescale: 30)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: time))
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        return url
    }

    private static func makeBlackPixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(fixtureSize.width),
            Int(fixtureSize.height),
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "PulseTests", code: Int(status))
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, 0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }
}
