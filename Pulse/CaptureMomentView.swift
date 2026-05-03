import AVFoundation
import AVKit
import SwiftUI

// MARK: - Phase

private enum CapturePhase {
    case recording
    case trimming(tempURL: URL)
    case processing
    case done
}

// MARK: - CaptureMomentView

struct CaptureMomentView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PulseStore
    let moment: CaptureMoment

    @State private var phase: CapturePhase = .recording
    @State private var errorMessage: String?
    @State private var momentIndex: Int = 0
    @State private var customText: String = ""
    @State private var localRetakeCount: Int = 0
    @State private var capturedAt: Date = Date()

    private let trimmer = VideoTrimmer()
    private let maxRetakes = 2

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch phase {
            case .recording:
                recordingView
            case .trimming(let tempURL):
                TrimView(
                    tempURL: tempURL,
                    customText: $customText,
                    canRetake: localRetakeCount < maxRetakes,
                    retakesLeft: maxRetakes - localRetakeCount,
                    onConfirm: { start in Task { await confirmTrim(tempURL: tempURL, startTime: start) } },
                    onRetake: {
                        localRetakeCount += 1
                        store.incrementRetake(for: moment.id)
                        withAnimation { phase = .recording }
                    }
                )
            case .processing:
                processingView
            case .done:
                doneView
            }
        }
        .onAppear {
            momentIndex = store.plan.moments.firstIndex(where: { $0.id == moment.id }) ?? 0
            customText = moment.customText ?? ""
            localRetakeCount = moment.retakeCount
        }
    }

    // MARK: - Recording View

    private var recordingView: some View {
        ZStack {
            CameraRecorderView(
                outputURL: store.tempClipURL(for: moment),
                duration: 5,
                onFinish: { url in
                    capturedAt = Date()
                    withAnimation { phase = .trimming(tempURL: url) }
                },
                onError: { error in errorMessage = error.localizedDescription }
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.top, 56)
                Spacer()
                recBadge
                    .padding(.bottom, 52)
                if let msg = errorMessage {
                    Text(msg)
                        .font(.footnote)
                        .padding(10)
                        .background(.black.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.white)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            VStack(spacing: 3) {
                if moment.kind == .free {
                    Text("FREE")
                        .font(.system(size: 26, weight: .black))
                        .foregroundStyle(.yellow)
                        .kerning(3)
                    Text("anytime slot")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    Text("#\(momentIndex + 1)")
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(.white)
                    Text(timeRangeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .monospaced()
                }
            }
            Spacer()
        }
    }

    private var timeRangeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let end = moment.scheduledAt.addingTimeInterval(5 * 60)
        return "\(f.string(from: moment.scheduledAt)) – \(f.string(from: end))"
    }

    private var recBadge: some View {
        HStack(spacing: 7) {
            Circle().fill(.red).frame(width: 9, height: 9)
            Text("5s REC")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .kerning(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.black.opacity(0.45))
        .clipShape(Capsule())
    }

    // MARK: - Processing / Done

    private var processingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Trimming…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var doneView: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.white)
            Text("Saved")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .kerning(2)
                .textCase(.uppercase)
        }
    }

    // MARK: - Trim Confirm

    private func confirmTrim(tempURL: URL, startTime: Double) async {
        phase = .processing

        do {
            let finalURL = store.clipURL(for: moment)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            _ = try await trimmer.trim(inputURL: tempURL, startTime: startTime, duration: 2.0, outputURL: finalURL)
            try? FileManager.default.removeItem(at: tempURL)

            store.setCustomText(customText, for: moment.id)
            store.registerCapture(momentID: moment.id, url: finalURL, capturedAt: capturedAt)
            withAnimation { phase = .done }
            try? await Task.sleep(nanoseconds: 900_000_000)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            withAnimation { phase = .trimming(tempURL: tempURL) }
        }
    }
}

// MARK: - TrimView

struct TrimView: View {
    let tempURL: URL
    @Binding var customText: String
    let canRetake: Bool
    let retakesLeft: Int
    let onConfirm: (Double) -> Void
    let onRetake: () -> Void

    @State private var thumbnails: [UIImage] = []
    @State private var committedOffset: CGFloat
    @GestureState private var dragDelta: CGFloat = 0
    @FocusState private var textFocused: Bool

    private let clipDuration: Double = 5.0
    private let selectDuration: Double = 2.0
    private let stripWidth: CGFloat = UIScreen.main.bounds.width - 40

    init(
        tempURL: URL,
        customText: Binding<String>,
        canRetake: Bool,
        retakesLeft: Int,
        onConfirm: @escaping (Double) -> Void,
        onRetake: @escaping () -> Void
    ) {
        self.tempURL = tempURL
        self._customText = customText
        self.canRetake = canRetake
        self.retakesLeft = retakesLeft
        self.onConfirm = onConfirm
        self.onRetake = onRetake
        let ww = (UIScreen.main.bounds.width - 40) * CGFloat(2.0 / 5.0)
        _committedOffset = State(initialValue: ((UIScreen.main.bounds.width - 40) - ww) / 2)
    }

    private var windowWidth: CGFloat { stripWidth * CGFloat(selectDuration / clipDuration) }
    private var maxDrag: CGFloat { max(stripWidth - windowWidth, 0) }
    private var displayX: CGFloat { min(max(committedOffset + dragDelta, 0), maxDrag) }
    private var startTime: Double {
        guard maxDrag > 0 else { return (clipDuration - selectDuration) / 2 }
        return Double(displayX / maxDrag) * (clipDuration - selectDuration)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .onTapGesture { textFocused = false }

            VStack(spacing: 0) {
                Spacer()

                // Time readout
                VStack(spacing: 5) {
                    Text(String(format: "%.1fs – %.1fs", startTime, startTime + selectDuration))
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Text("drag to pick your 2 seconds")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                        .kerning(1)
                }
                .padding(.bottom, 18)

                // Filmstrip
                ZStack(alignment: .leading) {
                    if thumbnails.isEmpty {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(0.08))
                            .overlay { ProgressView().tint(.white.opacity(0.4)).scaleEffect(0.7) }
                    } else {
                        HStack(spacing: 0) {
                            ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, img in
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: stripWidth / CGFloat(thumbnails.count), height: 72)
                                    .clipped()
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(.black.opacity(0.62))
                            .frame(width: displayX)
                        Rectangle()
                            .fill(.clear)
                            .frame(width: windowWidth)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(.white, lineWidth: 2.5)
                            )
                        Rectangle()
                            .fill(.black.opacity(0.62))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .frame(width: stripWidth, height: 72)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($dragDelta) { val, state, _ in state = val.translation.width }
                        .onEnded { val in
                            committedOffset = min(max(committedOffset + val.translation.width, 0), maxDrag)
                        }
                )

                // Custom text input — center text on the final clip.
                VStack(alignment: .leading, spacing: 6) {
                    Text("CENTER TEXT (optional)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                        .kerning(2)
                    TextField("", text: $customText, prompt: Text("e.g. coffee time").foregroundColor(.white.opacity(0.3)))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .focused($textFocused)
                        .submitLabel(.done)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .frame(width: stripWidth)
                .padding(.top, 18)

                // Buttons
                HStack(spacing: 12) {
                    Button {
                        if canRetake { onRetake() }
                    } label: {
                        VStack(spacing: 2) {
                            Text(canRetake ? "Retake" : "No more retakes")
                                .font(.system(size: 16, weight: .medium))
                            if canRetake {
                                Text("\(retakesLeft) left")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                        .foregroundStyle(canRetake ? .white.opacity(0.7) : .white.opacity(0.25))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.white.opacity(canRetake ? 0.08 : 0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(!canRetake)

                    Button {
                        textFocused = false
                        onConfirm(startTime)
                    } label: {
                        Text("Use this")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.top, 16)
                .frame(width: stripWidth)
                .padding(.bottom, 36)
            }
        }
        .task { await loadThumbnails() }
    }

    private func loadThumbnails() async {
        let asset = AVURLAsset(url: tempURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 290)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter  = CMTime(seconds: 0.15, preferredTimescale: 600)

        var imgs: [UIImage] = []
        for i in 0..<10 {
            let t = CMTime(seconds: Double(i) / 9.0 * clipDuration * 0.97, preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image {
                imgs.append(UIImage(cgImage: cg))
            }
        }
        await MainActor.run { thumbnails = imgs }
    }
}

// MARK: - CameraRecorderView

struct CameraRecorderView: UIViewControllerRepresentable {
    let outputURL: URL
    let duration: TimeInterval
    let onFinish: (URL) -> Void
    let onError: (Error) -> Void

    func makeUIViewController(context: Context) -> CameraRecorderViewController {
        let vc = CameraRecorderViewController()
        vc.outputURL = outputURL
        vc.duration = duration
        vc.onFinish = onFinish
        vc.onError = onError
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraRecorderViewController, context: Context) {}
}

// MARK: - CameraRecorderViewController

final class CameraRecorderViewController: UIViewController, AVCaptureFileOutputRecordingDelegate {
    var outputURL: URL!
    var duration: TimeInterval = 5
    var onFinish: ((URL) -> Void)?
    var onError: ((Error) -> Void)?

    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didStartRecording = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        Task { await configureAndStart() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureAndStart() async {
        do {
            let cameraOK = await AVCaptureDevice.requestAccess(for: .video)
            let audioOK  = await AVCaptureDevice.requestAccess(for: .audio)
            guard cameraOK, audioOK else { throw CameraRecorderError.permissionDenied }

            try configureSession()

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.insertSublayer(layer, at: 0)
            previewLayer = layer

            DispatchQueue.global(qos: .userInitiated).async {
                self.session.startRunning()
                DispatchQueue.main.async { self.startRecordingOnce() }
            }
        } catch {
            onError?(error)
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        session.sessionPreset = .high
        defer { session.commitConfiguration() }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraRecorderError.cameraUnavailable
        }
        let cameraInput = try AVCaptureDeviceInput(device: camera)
        if session.canAddInput(cameraInput) { session.addInput(cameraInput) }

        if let mic = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audioInput) { session.addInput(audioInput) }

        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
    }

    private func startRecordingOnce() {
        guard !didStartRecording else { return }
        didStartRecording = true

        if let conn = movieOutput.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        movieOutput.startRecording(to: outputURL, recordingDelegate: self)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        session.stopRunning()
        if let error { onError?(error) } else { onFinish?(url) }
    }
}

// MARK: - Errors

enum CameraRecorderError: LocalizedError {
    case permissionDenied, cameraUnavailable
    var errorDescription: String? {
        switch self {
        case .permissionDenied: "カメラとマイクの許可が必要です。"
        case .cameraUnavailable: "カメラを起動できませんでした。"
        }
    }
}
