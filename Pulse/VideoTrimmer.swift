import AVFoundation
import CoreImage
import Foundation

struct VideoTrimmer {
    func trim(
        inputURL: URL,
        startTime: Double,
        duration: Double,
        outputURL: URL,
        appliesVlogLook: Bool = false
    ) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)

        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else { throw TrimError.cannotCreateExport }

        export.outputURL = outputURL
        export.outputFileType = .mov
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        if appliesVlogLook {
            export.videoComposition = VlogClipLook.videoComposition(for: asset)
        }

        await export.export()
        if let error = export.error { throw error }
        return outputURL
    }

    func applyVlogLook(inputURL: URL, outputURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)

        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else { throw TrimError.cannotCreateExport }

        export.outputURL = outputURL
        export.outputFileType = .mov
        export.videoComposition = VlogClipLook.videoComposition(for: asset)

        await export.export()
        if let error = export.error { throw error }
        return outputURL
    }
}

enum TrimError: LocalizedError {
    case cannotCreateExport
    var errorDescription: String? { "トリミング用の書き出しセッションを作れませんでした。" }
}

enum VlogClipLook {
    static func videoComposition(for asset: AVAsset) -> AVVideoComposition {
        AVMutableVideoComposition(asset: asset) { request in
            let filtered = apply(to: request.sourceImage)
            request.finish(with: filtered, context: nil)
        }
    }

    static func apply(to source: CIImage) -> CIImage {
        var image = source

        if let filter = CIFilter(name: "CIHighlightShadowAdjust") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(0.5, forKey: "inputShadowAmount")
            filter.setValue(0.93, forKey: "inputHighlightAmount")
            image = filter.outputImage ?? image
        }

        // Apple Photos' Brilliance is not exposed as a public CIFilter.
        // CIVibrance is the closest public Core Image pass for this vlog look.
        if let filter = CIFilter(name: "CIVibrance") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(0.5, forKey: kCIInputAmountKey)
            image = filter.outputImage ?? image
        }

        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(0.05, forKey: kCIInputBrightnessKey)
            filter.setValue(0.86, forKey: kCIInputContrastKey)
            image = filter.outputImage ?? image
        }

        return image
    }
}
