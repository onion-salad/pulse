import AVFoundation
import CoreImage
import Foundation
import UIKit

struct VlogComposer {
    // Output: 9:16 portrait short-video format
    private let outputSize = CGSize(width: 1080, height: 1920)
    private let fps = CMTime(value: 1, timescale: 30)

    /// Compose a vlog from captured moments. Each moment can carry an optional
    /// `customText` (rendered in the center of the frame for that clip's duration)
    /// and a `capturedAt` timestamp (rendered like a stylish vlog overlay).
    func compose(moments: [CaptureMoment], outputURL: URL) async throws -> URL {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw VlogComposerError.cannotCreateTrack }

        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        // We'll bake an overlay layer per clip whose visibility is keyed to the clip's
        // [start, start+duration] range using CABasicAnimation on opacity.
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var overlayItems: [(text: String?, timestamp: Date?, range: CMTimeRange)] = []
        var cursor = CMTime.zero

        for moment in moments {
            guard let clipURL = moment.clipURL else { continue }
            let asset = AVURLAsset(url: clipURL)
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

            overlayItems.append((moment.customText, moment.capturedAt, compositionRange))

            cursor = cursor + duration
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = fps
        videoComposition.instructions = instructions

        // Build the overlay tree — one CALayer per clip, opacity-keyed to its range.
        let totalDuration = cursor
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: outputSize)
        videoLayer.frame = CGRect(origin: .zero, size: outputSize)
        parentLayer.addSublayer(videoLayer)

        for item in overlayItems {
            let overlay = makeOverlayLayer(text: item.text, timestamp: item.timestamp)
            overlay.frame = CGRect(origin: .zero, size: outputSize)
            overlay.opacity = 0
            attachOpacityKeyframes(layer: overlay, range: item.range, total: totalDuration)
            parentLayer.addSublayer(overlay)
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

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

    /// Backwards-compatible helper that wraps URLs in fake moments (no overlays).
    func compose(clips: [URL], outputURL: URL) async throws -> URL {
        let moments = clips.map { url in
            CaptureMoment(
                id: UUID(),
                scheduledAt: Date(),
                clipPath: url.path,
                status: .captured,
                kind: .hourly,
                customText: nil,
                retakeCount: 0,
                capturedAt: nil
            )
        }
        return try await compose(moments: moments, outputURL: outputURL)
    }

    // MARK: - Overlay layer

    private func makeOverlayLayer(text: String?, timestamp: Date?) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: outputSize)
        container.isGeometryFlipped = true   // top-left origin for sublayers' frames

        // Center text (if any) — large, bold, with subtle shadow for legibility.
        if let text, !text.isEmpty {
            let textLayer = CATextLayer()
            textLayer.string = text
            textLayer.alignmentMode = .center
            textLayer.font = UIFont.systemFont(ofSize: 92, weight: .heavy)
            textLayer.fontSize = 92
            textLayer.foregroundColor = UIColor.white.cgColor
            textLayer.contentsScale = 2
            textLayer.isWrapped = true
            textLayer.shadowColor = UIColor.black.cgColor
            textLayer.shadowOpacity = 0.55
            textLayer.shadowRadius = 12
            textLayer.shadowOffset = CGSize(width: 0, height: 4)

            let lineHeight: CGFloat = 110
            let estimatedLines = max(1, CGFloat(text.count) / 10.0)
            let textHeight = lineHeight * estimatedLines
            let textWidth = outputSize.width - 120
            textLayer.frame = CGRect(
                x: (outputSize.width - textWidth) / 2,
                y: (outputSize.height - textHeight) / 2,
                width: textWidth,
                height: textHeight
            )
            container.addSublayer(textLayer)
        }

        // Stylish timestamp — bottom-left, monospaced, all-caps date + time.
        if let timestamp {
            let timeFmt = DateFormatter()
            timeFmt.locale = Locale(identifier: "en_US_POSIX")
            timeFmt.dateFormat = "HH:mm"
            let dateFmt = DateFormatter()
            dateFmt.locale = Locale(identifier: "en_US_POSIX")
            dateFmt.dateFormat = "MMM d · EEE"

            // RED dot
            let dot = CALayer()
            let dotSize: CGFloat = 18
            dot.frame = CGRect(x: 60, y: outputSize.height - 200, width: dotSize, height: dotSize)
            dot.cornerRadius = dotSize / 2
            dot.backgroundColor = UIColor(red: 1, green: 0.2, blue: 0.2, alpha: 1).cgColor
            container.addSublayer(dot)

            // "REC" pill text
            let recLayer = CATextLayer()
            recLayer.string = "REC"
            recLayer.font = UIFont.monospacedSystemFont(ofSize: 26, weight: .bold)
            recLayer.fontSize = 26
            recLayer.foregroundColor = UIColor.white.cgColor
            recLayer.contentsScale = 2
            recLayer.frame = CGRect(x: 60 + dotSize + 10, y: outputSize.height - 205, width: 90, height: 30)
            container.addSublayer(recLayer)

            // Big time
            let timeLayer = CATextLayer()
            timeLayer.string = timeFmt.string(from: timestamp).uppercased()
            timeLayer.font = UIFont.monospacedSystemFont(ofSize: 96, weight: .heavy)
            timeLayer.fontSize = 96
            timeLayer.foregroundColor = UIColor.white.cgColor
            timeLayer.contentsScale = 2
            timeLayer.shadowColor = UIColor.black.cgColor
            timeLayer.shadowOpacity = 0.5
            timeLayer.shadowRadius = 8
            timeLayer.shadowOffset = CGSize(width: 0, height: 3)
            timeLayer.frame = CGRect(x: 60, y: outputSize.height - 160, width: 480, height: 110)
            container.addSublayer(timeLayer)

            // Small date
            let dateLayer = CATextLayer()
            dateLayer.string = dateFmt.string(from: timestamp).uppercased()
            dateLayer.font = UIFont.monospacedSystemFont(ofSize: 28, weight: .semibold)
            dateLayer.fontSize = 28
            dateLayer.foregroundColor = UIColor(white: 1, alpha: 0.85).cgColor
            dateLayer.contentsScale = 2
            dateLayer.shadowColor = UIColor.black.cgColor
            dateLayer.shadowOpacity = 0.5
            dateLayer.shadowRadius = 6
            dateLayer.shadowOffset = CGSize(width: 0, height: 2)
            dateLayer.frame = CGRect(x: 60, y: outputSize.height - 60, width: 480, height: 36)
            container.addSublayer(dateLayer)
        }

        return container
    }

    private func attachOpacityKeyframes(layer: CALayer, range: CMTimeRange, total: CMTime) {
        let start = CMTimeGetSeconds(range.start)
        let end = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0, 1, 1, 0]
        // Tiny fade on either end (50ms).
        let totalSec = max(CMTimeGetSeconds(total), 0.001)
        let fade = 0.05
        anim.keyTimes = [
            NSNumber(value: max(start - 0.0001, 0) / totalSec),
            NSNumber(value: min(start + fade, end) / totalSec),
            NSNumber(value: max(end - fade, start) / totalSec),
            NSNumber(value: min(end + 0.0001, totalSec) / totalSec)
        ]
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.duration = totalSec
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards
        anim.calculationMode = .linear
        layer.add(anim, forKey: "opacityWindow")
    }

    // MARK: - Fit transform

    private func fitTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGAffineTransform {
        let isRotated90 = abs(preferredTransform.b) > 0.5
        let visualSize = isRotated90
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize

        let scale = min(outputSize.width / visualSize.width, outputSize.height / visualSize.height)
        let centerX = (outputSize.width - visualSize.width * scale) / 2
        let centerY = (outputSize.height - visualSize.height * scale) / 2

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
