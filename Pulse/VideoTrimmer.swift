import AVFoundation
import Foundation

struct VideoTrimmer {
    func trim(inputURL: URL, startTime: Double, duration: Double, outputURL: URL) async throws -> URL {
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

        await export.export()
        if let error = export.error { throw error }
        return outputURL
    }
}

enum TrimError: LocalizedError {
    case cannotCreateExport
    var errorDescription: String? { "トリミング用の書き出しセッションを作れませんでした。" }
}
