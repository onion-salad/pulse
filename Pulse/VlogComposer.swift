import AVFoundation
import Foundation
import UIKit

struct VlogComposer {
    // Landscape 16:9 output
    private let outputSize = CGSize(width: 1920, height: 1080)
    private let fps = CMTime(value: 1, timescale: 30)

    func compose(moments: [CaptureMoment], outputURL: URL, musicID: String? = nil) async throws -> URL {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw VlogComposerError.cannotCreateTrack }

        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var overlayItems: [(text: String?, timestamp: Date?, range: CMTimeRange)] = []
        var cursor = CMTime.zero

        for moment in moments {
            guard let clipURL = moment.clipURL else { continue }
            let asset = AVURLAsset(url: clipURL)
            guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }

            let duration         = try await asset.load(.duration)
            let naturalSize      = try await srcVideo.load(.naturalSize)
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

        let totalDuration = cursor

        // MARK: Music track
        var musicCompositionTrack: AVMutableCompositionTrack? = nil
        if let musicID = musicID,
           let musicURL = Bundle.main.url(forResource: musicID, withExtension: "mp3") {
            let musicAsset = AVURLAsset(url: musicURL)
            if let musicSrc = try? await musicAsset.loadTracks(withMediaType: .audio).first,
               let musicDuration = try? await musicAsset.load(.duration),
               CMTimeCompare(musicDuration, .zero) > 0 {
                musicCompositionTrack = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
                )
                var m = CMTime.zero
                while CMTimeCompare(m, totalDuration) < 0 {
                    let remaining = CMTimeSubtract(totalDuration, m)
                    let insert = CMTimeMinimum(musicDuration, remaining)
                    try? musicCompositionTrack?.insertTimeRange(
                        CMTimeRange(start: .zero, duration: insert), of: musicSrc, at: m
                    )
                    m = CMTimeAdd(m, insert)
                }
            }
        }

        // MARK: Video composition
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = fps
        videoComposition.instructions = instructions

        // MARK: Text overlay layers
        let parentLayer = CALayer()
        let videoLayer  = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: outputSize)
        videoLayer.frame  = CGRect(origin: .zero, size: outputSize)
        parentLayer.addSublayer(videoLayer)

        for item in overlayItems {
            let overlay = makeOverlayLayer(text: item.text, timestamp: item.timestamp)
            overlay.frame = CGRect(origin: .zero, size: outputSize)
            overlay.opacity = 0
            attachOpacityKeyframes(layer: overlay, range: item.range, total: totalDuration)
            parentLayer.addSublayer(overlay)
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer
        )

        // MARK: Export
        guard let export = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality
        ) else { throw VlogComposerError.cannotCreateExport }

        export.outputURL  = outputURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.videoComposition = videoComposition

        // Audio mix: clip audio full volume, music at 25%
        var audioParams: [AVMutableAudioMixInputParameters] = []
        if let at = audioTrack {
            let p = AVMutableAudioMixInputParameters(track: at)
            p.setVolume(1.0, at: .zero)
            audioParams.append(p)
        }
        if let mt = musicCompositionTrack {
            let p = AVMutableAudioMixInputParameters(track: mt)
            p.setVolume(0.25, at: .zero)
            audioParams.append(p)
        }
        if !audioParams.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioParams
            export.audioMix = mix
        }

        await export.export()
        if let error = export.error { throw error }
        return outputURL
    }

    // MARK: - Overlay layer

    /// isGeometryFlipped = true → y=0 at top of frame, y increases downward.
    private func makeOverlayLayer(text: String?, timestamp: Date?) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: outputSize)
        container.isGeometryFlipped = true

        // Center text (bold, large, with shadow)
        if let text, !text.isEmpty {
            let tl = CATextLayer()
            tl.string = text
            tl.alignmentMode = .center
            tl.font = UIFont.systemFont(ofSize: 110, weight: .heavy)
            tl.fontSize = 110
            tl.foregroundColor = UIColor.white.cgColor
            tl.contentsScale = 2
            tl.isWrapped = true
            tl.shadowColor  = UIColor.black.cgColor
            tl.shadowOpacity = 0.6
            tl.shadowRadius  = 14
            tl.shadowOffset  = CGSize(width: 0, height: 4)
            let tw: CGFloat = outputSize.width - 240
            let th: CGFloat = 220
            tl.frame = CGRect(
                x: (outputSize.width - tw) / 2,
                y: (outputSize.height - th) / 2,
                width: tw, height: th
            )
            container.addSublayer(tl)
        }

        // Vlog-style timestamp (bottom-left)
        if let ts = timestamp {
            let timeFmt = DateFormatter(); timeFmt.locale = Locale(identifier: "en_US_POSIX"); timeFmt.dateFormat = "HH:mm"
            let dateFmt = DateFormatter(); dateFmt.locale = Locale(identifier: "en_US_POSIX"); dateFmt.dateFormat = "MMM d · EEE"

            let baseX: CGFloat = 60
            let baseY: CGFloat = outputSize.height - 220  // 860

            // Red REC dot
            let dot = CALayer()
            dot.frame = CGRect(x: baseX, y: baseY, width: 18, height: 18)
            dot.cornerRadius = 9
            dot.backgroundColor = UIColor(red: 1, green: 0.18, blue: 0.18, alpha: 1).cgColor
            container.addSublayer(dot)

            // "REC"
            let recLayer = CATextLayer()
            recLayer.string = "REC"
            recLayer.font = UIFont.monospacedSystemFont(ofSize: 24, weight: .bold)
            recLayer.fontSize = 24
            recLayer.foregroundColor = UIColor.white.cgColor
            recLayer.contentsScale = 2
            recLayer.frame = CGRect(x: baseX + 26, y: baseY - 3, width: 80, height: 28)
            container.addSublayer(recLayer)

            // Big HH:MM
            let timeLayer = CATextLayer()
            timeLayer.string = timeFmt.string(from: ts)
            timeLayer.font = UIFont.monospacedSystemFont(ofSize: 96, weight: .heavy)
            timeLayer.fontSize = 96
            timeLayer.foregroundColor = UIColor.white.cgColor
            timeLayer.contentsScale = 2
            timeLayer.shadowColor   = UIColor.black.cgColor
            timeLayer.shadowOpacity = 0.5
            timeLayer.shadowRadius  = 8
            timeLayer.shadowOffset  = CGSize(width: 0, height: 3)
            timeLayer.frame = CGRect(x: baseX, y: baseY + 24, width: 500, height: 110)
            container.addSublayer(timeLayer)

            // Small date
            let dateLayer = CATextLayer()
            dateLayer.string = dateFmt.string(from: ts).uppercased()
            dateLayer.font = UIFont.monospacedSystemFont(ofSize: 26, weight: .semibold)
            dateLayer.fontSize = 26
            dateLayer.foregroundColor = UIColor(white: 1, alpha: 0.85).cgColor
            dateLayer.contentsScale = 2
            dateLayer.shadowColor   = UIColor.black.cgColor
            dateLayer.shadowOpacity = 0.5
            dateLayer.shadowRadius  = 6
            dateLayer.shadowOffset  = CGSize(width: 0, height: 2)
            dateLayer.frame = CGRect(x: baseX, y: baseY + 138, width: 500, height: 36)
            container.addSublayer(dateLayer)
        }

        return container
    }

    private func attachOpacityKeyframes(layer: CALayer, range: CMTimeRange, total: CMTime) {
        let totalSec = max(CMTimeGetSeconds(total), 0.001)
        let start    = CMTimeGetSeconds(range.start)
        let end      = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
        let fade     = 0.04

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values   = [0, 1, 1, 0]
        anim.keyTimes = [
            NSNumber(value: max(start - 0.0001, 0) / totalSec),
            NSNumber(value: min(start + fade, end) / totalSec),
            NSNumber(value: max(end - fade, start) / totalSec),
            NSNumber(value: min(end + 0.0001, totalSec) / totalSec)
        ]
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.duration  = totalSec
        anim.isRemovedOnCompletion = false
        anim.fillMode  = .forwards
        anim.calculationMode = .linear
        layer.add(anim, forKey: "opacityWindow")
    }

    // MARK: - Fit transform

    private func fitTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGAffineTransform {
        let isRotated = abs(preferredTransform.b) > 0.5
        let visual = isRotated
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize

        let scale   = min(outputSize.width / visual.width, outputSize.height / visual.height)
        let centerX = (outputSize.width  - visual.width  * scale) / 2
        let centerY = (outputSize.height - visual.height * scale) / 2

        var t = preferredTransform
        t.a *= scale; t.b *= scale; t.c *= scale; t.d *= scale
        t.tx = t.tx * scale + centerX
        t.ty = t.ty * scale + centerY
        return t
    }
}

enum VlogComposerError: LocalizedError {
    case cannotCreateTrack, cannotCreateExport
    var errorDescription: String? {
        switch self {
        case .cannotCreateTrack:  "動画トラックを作れませんでした。"
        case .cannotCreateExport: "書き出しセッションを作れませんでした。"
        }
    }
}
