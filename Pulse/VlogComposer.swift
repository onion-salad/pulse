import AVFoundation
import Foundation

struct VlogComposer {
    // Output: 9:16 portrait short-video format
    private let outputSize = CGSize(width: 1080, height: 1920)
    private let fps = CMTime(value: 1, timescale: 30)

    func compose(clips: [URL], outputURL: URL) async throws -> URL {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw VlogComposerError.cannotCreateTrack }

        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero

        for clip in clips {
            let asset = AVURLAsset(url: clip)
            guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }

            let duration = try await asset.load(.duration)
            let naturalSize = try await srcVideo.load(.naturalSize)
            let preferredTransform = try await srcVideo.load(.preferredTransform)

            let clipRange = CMTimeRange(start: .zero, duration: duration)
            try videoTrack.insertTimeRange(clipRange, of: srcVideo, at: cursor)

            if let srcAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack?.insertTimeRange(clipRange, of: srcAudio, at: cursor)
            }

            let compositionRange = CMTimeRange(start: cursor, duration: duration)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layerInstruction.setTransform(
                fitTransform(naturalSize: naturalSize, preferredTransform: preferredTransform),
                at: cursor
            )

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = compositionRange
            instruction.layerInstructions = [layerInstruction]
            instructions.append(instruction)

            cursor = cursor + duration
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = fps
        videoComposition.instructions = instructions

        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else { throw VlogComposerError.cannotCreateExport }

        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.videoComposition = videoComposition

        await export.export()
        if let error = export.error { throw error }
        return outputURL
    }

    // Builds a transform that applies the clip's preferred rotation and scales it
    // to fill the output frame while preserving aspect ratio (letterboxed).
    private func fitTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGAffineTransform {
        // Determine visual size after the preferred transform (rotation)
        let isRotated90 = abs(preferredTransform.b) > 0.5
        let visualSize = isRotated90
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize

        let scale = min(outputSize.width / visualSize.width, outputSize.height / visualSize.height)
        let centerX = (outputSize.width - visualSize.width * scale) / 2
        let centerY = (outputSize.height - visualSize.height * scale) / 2

        // Scale the components of the preferred transform, then add centering offset
        var t = preferredTransform
        t.a  *= scale;  t.b  *= scale
        t.c  *= scale;  t.d  *= scale
        t.tx  = t.tx * scale + centerX
        t.ty  = t.ty * scale + centerY
        return t
    }
}

enum VlogComposerError: LocalizedError {
    case cannotCreateTrack
    case cannotCreateExport

    var errorDescription: String? {
        switch self {
        case .cannotCreateTrack:  "動画トラックを作れませんでした。"
        case .cannotCreateExport: "書き出しセッションを作れませんでした。"
        }
    }
}
