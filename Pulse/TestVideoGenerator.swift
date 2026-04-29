import AVFoundation
import UIKit

struct TestVideoGenerator {
    // Generates a 2-second portrait (1080×1920) video with a solid hue and clip number.
    func generateClip(number: Int, outputURL: URL, duration: Double = 2.0) async throws -> URL {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let width = 1080, height = 1920
        let fps: Int32 = 30

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(duration * Double(fps))
        let hue = CGFloat(number - 1) / 11.0
        let color = UIColor(hue: hue, saturation: 0.6, brightness: 0.88, alpha: 1.0)

        for frame in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            let t = CMTime(value: CMTimeValue(frame), timescale: fps)
            if let buf = makeFrame(number: number, frame: frame, total: totalFrames,
                                   color: color, width: width, height: height,
                                   pool: adaptor.pixelBufferPool) {
                adaptor.append(buf, withPresentationTime: t)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return outputURL
    }

    private func makeFrame(number: Int, frame: Int, total: Int,
                           color: UIColor, width: Int, height: Int,
                           pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buf: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buf) }
        else { CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buf) }
        guard let buf else { return nil }

        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buf),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Solid background
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Dark gradient at top for label readability
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 4))

        // Progress bar at bottom
        let progress = CGFloat(frame) / CGFloat(max(total - 1, 1))
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.45).cgColor)
        ctx.fill(CGRect(x: 0, y: height - 28, width: Int(CGFloat(width) * progress), height: 28))

        UIGraphicsPushContext(ctx)

        // Large clip number
        let numStr = "\(number)" as NSString
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 420, weight: .black),
            .foregroundColor: UIColor.white.withAlphaComponent(0.9)
        ]
        let numSize = numStr.size(withAttributes: numAttrs)
        numStr.draw(
            at: CGPoint(x: (CGFloat(width) - numSize.width) / 2,
                        y: (CGFloat(height) - numSize.height) / 2),
            withAttributes: numAttrs
        )

        // "TEST CLIP" label
        let label = "TEST CLIP" as NSString
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 72, weight: .bold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.4)
        ]
        let labelSize = label.size(withAttributes: labelAttrs)
        label.draw(
            at: CGPoint(x: (CGFloat(width) - labelSize.width) / 2, y: 180),
            withAttributes: labelAttrs
        )

        UIGraphicsPopContext()
        return buf
    }
}
