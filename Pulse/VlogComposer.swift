import AVFoundation
import Foundation
import UIKit

struct VlogComposer {
    // Landscape 16:9 output
    private let outputSize = CGSize(width: 1920, height: 1080)
    private let fps = CMTime(value: 1, timescale: 30)

    @MainActor
    func makePlayerItem(
        moments: [CaptureMoment],
        musicID: String? = nil,
        musicVolume: Float = 0.25,
        clipVolumes: [UUID: Float] = [:]
    ) async throws -> AVPlayerItem {
        let package = try await makeRenderPackage(
            moments: moments,
            musicID: musicID,
            musicVolume: musicVolume,
            clipVolumes: clipVolumes,
            includesOverlayLayers: false
        )
        let item = AVPlayerItem(asset: package.composition)
        item.videoComposition = package.videoComposition
        item.audioMix = package.audioMix
        return item
    }

    func compose(
        moments: [CaptureMoment],
        outputURL: URL,
        musicID: String? = nil,
        musicVolume: Float = 0.25,
        clipVolumes: [UUID: Float] = [:]
    ) async throws -> URL {
        let package = try await makeRenderPackage(
            moments: moments,
            musicID: musicID,
            musicVolume: musicVolume,
            clipVolumes: clipVolumes,
            includesOverlayLayers: true
        )

        guard let export = AVAssetExportSession(
            asset: package.composition, presetName: AVAssetExportPresetHighestQuality
        ) else { throw VlogComposerError.cannotCreateExport }

        export.outputURL  = outputURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.videoComposition = package.videoComposition
        export.audioMix = package.audioMix

        await export.export()
        if let error = export.error { throw error }
        return outputURL
    }

    private func makeRenderPackage(
        moments: [CaptureMoment],
        musicID: String?,
        musicVolume: Float,
        clipVolumes: [UUID: Float],
        includesOverlayLayers: Bool
    ) async throws -> VlogRenderPackage {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw VlogComposerError.cannotCreateTrack }

        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var overlayItems: [(text: String?, timestamp: Date?, range: CMTimeRange)] = []
        var clipAudioItems: [(volume: Float, range: CMTimeRange)] = []
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
            let compositionRange = CMTimeRange(start: cursor, duration: duration)
            if let srcAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack?.insertTimeRange(clipRange, of: srcAudio, at: cursor)
                clipAudioItems.append((clipVolumes[moment.id] ?? 1.0, compositionRange))
            }

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

        if includesOverlayLayers {
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
        }

        var audioParams: [AVMutableAudioMixInputParameters] = []
        if let at = audioTrack {
            let p = AVMutableAudioMixInputParameters(track: at)
            for item in clipAudioItems {
                p.setVolume(item.volume, at: item.range.start)
            }
            audioParams.append(p)
        }
        if let mt = musicCompositionTrack {
            let p = AVMutableAudioMixInputParameters(track: mt)
            p.setVolume(musicVolume, at: .zero)
            audioParams.append(p)
        }
        if !audioParams.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioParams
            return VlogRenderPackage(composition: composition, videoComposition: videoComposition, audioMix: mix)
        }

        return VlogRenderPackage(composition: composition, videoComposition: videoComposition, audioMix: nil)
    }

    // MARK: - Overlay layer

    /// isGeometryFlipped = true -> y=0 at top of frame, y increases downward.
    private func makeOverlayLayer(text: String?, timestamp: Date?) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: outputSize)
        container.isGeometryFlipped = true

        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmedText, !trimmedText.isEmpty, timestamp == nil {
            let tl = CATextLayer()
            tl.string = trimmedText
            tl.alignmentMode = .center
            tl.font = UIFont.monospacedSystemFont(ofSize: 110, weight: .heavy).fontName as CFTypeRef
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

        if let ts = timestamp {
            let timeFmt = DateFormatter()
            timeFmt.locale = Locale(identifier: "en_US_POSIX")
            timeFmt.dateFormat = "HH:mm"

            let timeLayer = CATextLayer()
            timeLayer.string = timeFmt.string(from: ts)
            timeLayer.alignmentMode = .center
            timeLayer.font = UIFont.monospacedSystemFont(ofSize: 130, weight: .heavy).fontName as CFTypeRef
            timeLayer.fontSize = 130
            timeLayer.foregroundColor = UIColor.white.cgColor
            timeLayer.contentsScale = 2
            timeLayer.shadowColor   = UIColor.black.cgColor
            timeLayer.shadowOpacity = 0.5
            timeLayer.shadowRadius  = 12
            timeLayer.shadowOffset  = CGSize(width: 0, height: 4)
            let height: CGFloat = 160
            let hasCaption = !(trimmedText?.isEmpty ?? true)
            timeLayer.frame = CGRect(
                x: 0,
                y: (outputSize.height - height) / 2 - (hasCaption ? 48 : 0),
                width: outputSize.width,
                height: height
            )
            container.addSublayer(timeLayer)

            if let trimmedText, !trimmedText.isEmpty {
                let captionFontSize: CGFloat = 72
                let captionLayer = CATextLayer()
                captionLayer.string = trimmedText
                captionLayer.alignmentMode = .center
                captionLayer.font = UIFont.monospacedSystemFont(ofSize: captionFontSize, weight: .heavy).fontName as CFTypeRef
                captionLayer.fontSize = captionFontSize
                captionLayer.foregroundColor = UIColor.white.withAlphaComponent(0.92).cgColor
                captionLayer.contentsScale = 2
                captionLayer.isWrapped = true
                captionLayer.shadowColor = UIColor.black.cgColor
                captionLayer.shadowOpacity = 0.45
                captionLayer.shadowRadius = 10
                captionLayer.shadowOffset = CGSize(width: 0, height: 3)
                captionLayer.frame = CGRect(
                    x: 180,
                    y: outputSize.height / 2 + 52,
                    width: outputSize.width - 360,
                    height: 150
                )
                container.addSublayer(captionLayer)
            }
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
        let naturalRect = CGRect(origin: .zero, size: naturalSize)
        let preferredBounds = naturalRect.applying(preferredTransform)
        let normalizedPreferred = preferredTransform.concatenating(
            CGAffineTransform(
                translationX: -preferredBounds.minX,
                y: -preferredBounds.minY
            )
        )

        let visualSize = CGSize(
            width: abs(preferredBounds.width),
            height: abs(preferredBounds.height)
        )
        let rotateLeft = CGAffineTransform(rotationAngle: -.pi / 2)
            .concatenating(CGAffineTransform(translationX: 0, y: visualSize.width))
        let rotatedSize = CGSize(width: visualSize.height, height: visualSize.width)
        let scale = min(outputSize.width / rotatedSize.width, outputSize.height / rotatedSize.height)
        let centerX = (outputSize.width - rotatedSize.width * scale) / 2
        let centerY = (outputSize.height - rotatedSize.height * scale) / 2

        return normalizedPreferred
            .concatenating(rotateLeft)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: centerX, y: centerY))
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

private struct VlogRenderPackage {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVAudioMix?
}
