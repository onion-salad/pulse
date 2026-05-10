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

private enum RecordingProgressEdge {
    case leading
    case trailing
    case top
}

// MARK: - CaptureMomentView

struct CaptureMomentView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PulseStore
    let moment: CaptureMoment
    var onComplete: (() -> Void)?

    @State private var phase: CapturePhase = .recording
    @State private var errorMessage: String?
    @State private var momentIndex: Int = 0
    @State private var customText: String = ""
    @State private var localRetakeCount: Int = 0
    @State private var capturedAt: Date = Date()
    @State private var recordingProgress: CGFloat = 0
    @State private var progressEdge: RecordingProgressEdge = .trailing
    @State private var recordingTrigger: UUID?
    @State private var isRecording = false
    @State private var currentTime = Date()

    private let trimmer = VideoTrimmer()
    private let maxRetakes = 2
    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
        GeometryReader { proxy in
            let safeBottom = proxy.safeAreaInsets.bottom

            ZStack(alignment: .bottom) {
                CameraRecorderView(
                    outputURL: store.tempClipURL(for: moment),
                    duration: 2,
                    recordingTrigger: recordingTrigger,
                    onFinish: { url in
                        capturedAt = Date()
                        isRecording = false
                        Task { await saveFixedClip(tempURL: url) }
                    },
                    onError: { error in
                        isRecording = false
                        errorMessage = error.localizedDescription
                    }
                )
                .ignoresSafeArea()

                currentTimeOverlay(height: proxy.size.height)
                    .allowsHitTesting(false)

                if let msg = errorMessage {
                    Text(msg)
                        .font(.footnote)
                        .padding(10)
                        .background(.black.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 150)
                }

                Button {
                    startManualRecording()
                } label: {
                    captureIndicator
                }
                .buttonStyle(.plain)
                .disabled(isRecording)
                    .padding(.bottom, max(safeBottom, 2))
                    .offset(y: 54)
            }
            .overlay(alignment: progressBarAlignment) {
                if isRecording {
                    recordingProgressBar(size: proxy.size)
                }
            }
            .onAppear {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                updateProgressEdge()
            }
            .onDisappear {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                updateProgressEdge()
            }
            .onReceive(clockTimer) { date in
                currentTime = date
            }
        }
    }

    private func currentTimeOverlay(height: CGFloat) -> some View {
        Text(currentTimeLabel)
            .font(.system(size: captureClockFontSize(height: height), weight: .heavy, design: .monospaced))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
            .rotationEffect(.degrees(90))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var currentTimeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: currentTime)
    }

    private func captureClockFontSize(height: CGFloat) -> CGFloat {
        min(max(height * 0.058, 38), 52)
    }

    private var captureIndicator: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.34), lineWidth: 4)
                .frame(width: 82, height: 82)
            Circle()
                .fill(.white.opacity(0.92))
                .frame(width: 68, height: 68)
            Image(systemName: "camera.fill")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.black)
                .rotationEffect(.degrees(90))
        }
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
        .accessibilityLabel("撮影開始")
    }

    private func recordingProgressBar(size: CGSize) -> some View {
        Group {
            switch progressEdge {
            case .leading, .trailing:
                verticalRecordingProgressBar(height: size.height)
                    .frame(width: 4, height: size.height)
                    .padding(progressEdge == .leading ? .leading : .trailing, 1)
            case .top:
                horizontalRecordingProgressBar(width: size.width)
                    .frame(width: size.width, height: 4)
                    .padding(.top, 1)
            }
        }
        .ignoresSafeArea()
    }

    private func verticalRecordingProgressBar(height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.16))
            Rectangle()
                .fill(.white)
                .frame(height: height * recordingProgress)
        }
        .clipShape(Capsule())
    }

    private func horizontalRecordingProgressBar(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(.white.opacity(0.16))
            Rectangle()
                .fill(.white)
                .frame(width: width * recordingProgress)
        }
        .clipShape(Capsule())
    }

    private var progressBarAlignment: Alignment {
        switch progressEdge {
        case .leading: return .leading
        case .trailing: return .trailing
        case .top: return .top
        }
    }

    private func updateProgressEdge() {
        progressEdge = .trailing
    }

    private func startManualRecording() {
        updateProgressEdge()
        errorMessage = nil
        isRecording = true
        recordingTrigger = UUID()
        startRecordingProgress()
    }

    private func startRecordingProgress() {
        recordingProgress = 0
        withAnimation(.linear(duration: 2)) {
            recordingProgress = 1
        }
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
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            Text("SAVE")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(.white)
                .kerning(2)
        }
        .rotationEffect(.degrees(90))
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
            if let onComplete {
                onComplete()
            } else {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
            withAnimation { phase = .trimming(tempURL: tempURL) }
        }
    }

    private func saveFixedClip(tempURL: URL) async {
        phase = .processing

        do {
            let finalURL = store.clipURL(for: moment)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: finalURL)

            store.setCustomText(customText, for: moment.id)
            store.registerCapture(momentID: moment.id, url: finalURL, capturedAt: capturedAt)
            withAnimation { phase = .done }
            try? await Task.sleep(nanoseconds: 700_000_000)
            if let onComplete {
                onComplete()
            } else {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
            withAnimation { phase = .recording }
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
                imgs.append(UIImage(cgImage: cg).rotatedLeft())
            }
        }
        await MainActor.run { thumbnails = imgs }
    }
}

// MARK: - CameraRecorderView

struct CameraRecorderView: UIViewControllerRepresentable {
    let outputURL: URL
    let duration: TimeInterval
    let recordingTrigger: UUID?
    let onFinish: (URL) -> Void
    let onError: (Error) -> Void

    func makeUIViewController(context: Context) -> CameraRecorderViewController {
        let vc = CameraRecorderViewController()
        vc.outputURL = outputURL
        vc.duration = duration
        vc.recordingTrigger = recordingTrigger
        vc.onFinish = onFinish
        vc.onError = onError
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraRecorderViewController, context: Context) {
        uiViewController.refreshPreviewOrientation()
        uiViewController.startRecordingIfNeeded(trigger: recordingTrigger)
    }
}

// MARK: - CameraRecorderViewController

final class CameraRecorderViewController: UIViewController, AVCaptureFileOutputRecordingDelegate {
    var outputURL: URL!
    var duration: TimeInterval = 5
    var recordingTrigger: UUID?
    var onFinish: ((URL) -> Void)?
    var onError: ((Error) -> Void)?

    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didStartRecording = false
    private var lastHandledTrigger: UUID?
    private var allowsSession = true

    deinit {
        allowsSession = false
        session.stopRunning()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        Task { await configureAndStart() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        applyPreviewOrientation()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        allowsSession = false
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        } else {
            session.stopRunning()
        }
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
            applyPreviewOrientation()

            DispatchQueue.global(qos: .userInitiated).async {
                guard self.allowsSession else { return }
                self.session.startRunning()
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

    func startRecordingIfNeeded(trigger: UUID?) {
        guard let trigger, trigger != lastHandledTrigger else { return }
        lastHandledTrigger = trigger
        startRecordingOnce()
    }

    func refreshPreviewOrientation() {
        applyPreviewOrientation()
    }

    private func startRecordingOnce() {
        guard !didStartRecording else { return }
        didStartRecording = true

        if let conn = movieOutput.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = currentVideoOrientation()
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

    private func applyPreviewOrientation() {
        if let conn = previewLayer?.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = resolvedPreviewOrientation()
        }
    }

    private func resolvedPreviewOrientation() -> AVCaptureVideoOrientation {
        currentVideoOrientation()
    }

    private func currentVideoOrientation() -> AVCaptureVideoOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .portrait:
            return .portrait
        default:
            return view.bounds.width > view.bounds.height ? .landscapeRight : .portrait
        }
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
