import AVFoundation
import AVKit
import Photos
import SwiftUI

// MARK: - ArchiveView

struct ArchiveView: View {
    @EnvironmentObject private var store: PulseStore
    @State private var selectedVlog: IdentifiableURL?
    @State private var pendingDelete: IdentifiableURL?
    @State private var showingComposer = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if store.vlogs.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                            .padding(.horizontal, 22)
                            .padding(.top, 16)

                        LazyVStack(spacing: 14) {
                            ForEach(store.vlogs, id: \.absoluteString) { url in
                                VlogCardView(
                                    url: url,
                                    onDelete: {
                                        pendingDelete = IdentifiableURL(url: url)
                                    }
                                )
                                    .onTapGesture { selectedVlog = IdentifiableURL(url: url) }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 20)

                        Color.clear.frame(height: 50)
                    }
                }
            }

            VStack {
                Spacer()
                Button {
                    AppHaptics.light()
                    showingComposer = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 74, height: 74)
                        .background(.white)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 18)
            }

            if let pendingDelete {
                DeleteConfirmPopup(
                    title: "このvlogを削除しますか？",
                    message: "アーカイブから消えます。",
                    onCancel: {
                        self.pendingDelete = nil
                    },
                    onDelete: {
                        store.deleteVlog(url: pendingDelete.url)
                        self.pendingDelete = nil
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: pendingDelete != nil)
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $selectedVlog) { item in
            VlogPlayerView(url: item.url)
        }
        .fullScreenCover(isPresented: $showingComposer) {
            ArchiveComposerView()
                .environmentObject(store)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ARCHIVE")
                .font(.system(size: 32, weight: .black))
                .foregroundStyle(.white)
                .kerning(5)
            Text("\(store.vlogs.count) day\(store.vlogs.count == 1 ? "" : "s") captured")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .kerning(1.5)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.15))
            Text("No memories yet")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white.opacity(0.25))
            Text("Finish a day to see your vlog here")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.15))
        }
    }
}

// MARK: - VlogCardView

struct VlogCardView: View {
    let url: URL
    let onDelete: () -> Void
    @State private var thumbnail: UIImage?
    @State private var didFail = false
    @State private var isSavingToPhotos = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else if didFail {
                    Color.white.opacity(0.07)
                        .overlay {
                            Image(systemName: "film")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.24))
                        }
                } else {
                    Color.white.opacity(0.07)
                        .overlay {
                            ProgressView()
                                .tint(.white.opacity(0.3))
                                .scaleEffect(0.65)
                        }
                }
            }

            // Play icon
            Image(systemName: "play.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Date pill
            Text(dateLabel)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(9)

            HStack {
                Spacer()
                VStack {
                    HStack(spacing: 8) {
                        Button {
                            Task { await saveVideoToPhotos() }
                        } label: {
                            ZStack {
                                if isSavingToPhotos {
                                    ProgressView()
                                        .tint(.white)
                                        .scaleEffect(0.55)
                                } else {
                                    Image(systemName: "arrow.down.to.line")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: 34, height: 34)
                            .background(.black.opacity(0.58))
                            .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isSavingToPhotos)

                        Button {
                            onDelete()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(.black.opacity(0.58))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(9)
                    Spacer()
                }
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: url) {
            didFail = false
            thumbnail = await makeThumbnail()
            didFail = thumbnail == nil
        }
    }

    private var dateLabel: String {
        let stem = url.deletingPathExtension().lastPathComponent
        let raw = stem.replacingOccurrences(of: "vlog-", with: "")
        let dateStr = String(raw.prefix(10))
        let parse = DateFormatter(); parse.dateFormat = "yyyy-MM-dd"; parse.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parse.date(from: dateStr) else { return dateStr }
        let display = DateFormatter(); display.dateFormat = "MMM d"; display.locale = Locale(identifier: "en_US")
        return display.string(from: date).uppercased()
    }

    private func makeThumbnail() async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 700, height: 400)
        let t = CMTime(seconds: 0.3, preferredTimescale: 600)
        guard let cgImg = try? await gen.image(at: t).image else { return nil }
        return UIImage(cgImage: cgImg)
    }

    @MainActor
    private func saveVideoToPhotos() async {
        guard !isSavingToPhotos else { return }
        AppHaptics.light()
        isSavingToPhotos = true
        defer { isSavingToPhotos = false }

        do {
            let status = await PHPhotoLibrary.requestAddOnlyAuthorization()
            guard status == .authorized || status == .limited else { return }
            try await PHPhotoLibrary.shared().saveVideoToLibrary(at: url)
            AppHaptics.success()
        } catch {
            didFail = true
        }
    }
}

private extension PHPhotoLibrary {
    static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    func saveVideoToLibrary(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoLibrarySaveError.failed)
                }
            }
        }
    }
}

private enum PhotoLibrarySaveError: Error {
    case failed
}

// MARK: - VlogPlayerView

struct VlogPlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Circle().fill(.black.opacity(0.5)))
                    }
                    .padding(.trailing, 20)
                    .padding(.top, 56)
                }
                Spacer()

                Text(dateLabel)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white.opacity(0.5))
                    .kerning(2)
                    .textCase(.uppercase)
                    .padding(.bottom, 48)
            }
        }
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }

    private var dateLabel: String {
        let stem = url.deletingPathExtension().lastPathComponent
        let raw = stem.replacingOccurrences(of: "vlog-", with: "")
        let dateStr = String(raw.prefix(10))
        let parse = DateFormatter(); parse.dateFormat = "yyyy-MM-dd"; parse.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parse.date(from: dateStr) else { return dateStr }
        let display = DateFormatter(); display.dateFormat = "EEEE, MMMM d"; display.locale = Locale(identifier: "en_US")
        return display.string(from: date)
    }
}

// MARK: - Archive Composer

struct ArchiveComposerView: View {
    @EnvironmentObject private var store: PulseStore
    @Environment(\.dismiss) private var dismiss
    private let startsInEditor: Bool
    private let sourceColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    @State private var step: ArchiveComposerStep = .select
    @State private var selectedIDs: Set<UUID> = []
    @State private var selectedMusicID = MusicTrack.defaultFor(dateKey: "archive").id
    @State private var previewItem: AVPlayerItem?
    @State private var previewPlayer = AVPlayer()
    @State private var isRendering = false
    @State private var isSaving = false
    @State private var saveProgress = 0.0
    @State private var didSave = false
    @State private var didPrepareInitialState = false
    @State private var editorTab: ArchiveComposerTab = .music
    @State private var previewCurrentTime = 0.0
    @State private var previewDuration = 0.0
    @State private var isPreviewPlaying = false
    @State private var previewRefreshTask: Task<Void, Never>?
    @State private var clipTimeline: [ArchiveClipTimelineEntry] = []
    @State private var showsPreviewControls = true
    @State private var showingFullscreenPreview = false

    init(initialMomentIDs: Set<UUID> = [], startsInEditor: Bool = false) {
        self.startsInEditor = startsInEditor
        _selectedIDs = State(initialValue: initialMomentIDs)
        _step = State(initialValue: startsInEditor ? .preview : .select)
    }

    private var sourceMoments: [CaptureMoment] { store.archiveSourceMoments }

    private var selectedMoments: [CaptureMoment] {
        sourceMoments.filter { selectedIDs.contains($0.id) }
    }

    private var groupedSourceMoments: [ArchiveSourceGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sourceMoments) { moment in
            calendar.startOfDay(for: moment.capturedAt ?? moment.scheduledAt)
        }
        return grouped
            .map { date, moments in
                ArchiveSourceGroup(
                    date: date,
                    title: archiveDateTitle(for: date),
                    moments: moments.sorted { ($0.capturedAt ?? $0.scheduledAt) < ($1.capturedAt ?? $1.scheduledAt) }
                )
            }
            .sorted { $0.date > $1.date }
    }

    private var currentPreviewMoment: CaptureMoment? {
        guard previewItem != nil else { return nil }
        guard let entry = clipTimeline.first(where: { previewCurrentTime >= $0.start && previewCurrentTime < $0.end }) else {
            return selectedMomentsForRender.last
        }
        return selectedMomentsForRender.first { $0.id == entry.id }
    }

    @State private var musicVolume = 0.25
    @State private var clipVolumes: [UUID: Double] = [:]
    @State private var clipTexts: [UUID: String] = [:]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                composerHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                switch step {
                case .select:
                    materialPicker
                case .preview:
                    previewPane
                }
            }
        }
        .overlay {
            if showingFullscreenPreview {
                ArchiveFullscreenPreviewView(
                    player: previewPlayer,
                    isPlaying: isPreviewPlaying,
                    currentTime: previewCurrentTime,
                    duration: previewDuration,
                    moment: currentPreviewMoment,
                    showsControls: $showsPreviewControls,
                    onDismiss: {
                        showingFullscreenPreview = false
                        showsPreviewControls = true
                    },
                    onTogglePlay: togglePreviewPlayback,
                    onSeek: seekPreview(to:)
                )
                .transition(.opacity)
                .zIndex(20)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showingFullscreenPreview)
        .preferredColorScheme(.dark)
        .onAppear {
            guard !didPrepareInitialState else { return }
            didPrepareInitialState = true
            if startsInEditor {
                prepareEditor()
                Task { await renderPreview() }
            }
        }
        .onDisappear {
            previewRefreshTask?.cancel()
            previewPlayer.pause()
        }
        .task {
            await monitorPreviewPlayback()
        }
    }

    private var composerHeader: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(headerTitle)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white.opacity(0.74))
                .kerning(2)

            Spacer()

            Color.clear.frame(width: 38, height: 38)
        }
    }

    private var headerTitle: String {
        switch step {
        case .select: "素材を選択"
        case .preview: "アーカイブ作成"
        }
    }

    private var materialPicker: some View {
        VStack(spacing: 0) {
            if sourceMoments.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "film")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.18))
                    Text("素材がまだありません")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 12) {
                        ForEach(groupedSourceMoments) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(group.title)
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(.white.opacity(0.42))
                                    .kerning(1.4)
                                    .padding(.horizontal, 4)

                                LazyVGrid(columns: sourceColumns, spacing: 8) {
                                    ForEach(group.moments) { moment in
                                        ArchiveSourceCard(
                                            moment: moment,
                                            isSelected: selectedIDs.contains(moment.id)
                                        )
                                        .onTapGesture {
                                            if selectedIDs.contains(moment.id) {
                                                selectedIDs.remove(moment.id)
                                            } else {
                                                selectedIDs.insert(moment.id)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 120)
                }
            }

            bottomAction(title: "次へ", disabled: selectedIDs.isEmpty) {
                prepareEditor()
                step = .preview
                Task { await renderPreview() }
            }
        }
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            previewStage
                .padding(.horizontal, 16)
                .padding(.top, 18)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    composerTabs
                        .padding(.top, 2)

                    switch editorTab {
                    case .music:
                        musicEditor
                    case .clips:
                        clipsEditor
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 120)
            }

            bottomAction(
                title: isSaving ? "保存中" : "アーカイブに保存",
                disabled: previewItem == nil || isRendering || isSaving,
                progress: isSaving ? saveProgress : nil
            ) {
                Task { await saveArchive() }
            }
        }
    }

    private var previewStage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.055))

            if previewItem != nil {
                ArchivePreviewPlayer(player: previewPlayer)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            showsPreviewControls.toggle()
                        }
                    }
            } else {
                Text("PREVIEW")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white.opacity(0.22))
                    .kerning(2)
            }

            if isRendering {
                Color.black.opacity(0.46)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                ProgressView()
                    .tint(.white)
            }

            if let moment = currentPreviewMoment {
                previewTextOverlay(moment: moment)
                    .allowsHitTesting(false)
            }

            if showsPreviewControls {
                VStack {
                    Spacer()
                    ArchivePreviewControls(
                        isPlaying: isPreviewPlaying,
                        currentTime: previewCurrentTime,
                        duration: previewDuration,
                        includesFullscreen: true,
                        onTogglePlay: togglePreviewPlayback,
                        onSeek: seekPreview(to:),
                        onFullscreen: { showingFullscreenPreview = true }
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
                .transition(.opacity)
            }
        }
        .frame(height: 246)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func previewTextOverlay(moment: CaptureMoment) -> some View {
        VStack(spacing: 6) {
            Text(moment.captureTimeLabel)
                .font(.system(size: 44, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.65), radius: 10, y: 3)

            if let text = moment.customText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                Text(text)
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.62), radius: 8, y: 2)
                    .padding(.horizontal, 28)
            }
        }
        .padding(.bottom, 26)
    }

    private var composerTabs: some View {
        HStack(spacing: 4) {
            ForEach(ArchiveComposerTab.allCases, id: \.self) { tab in
                Button {
                    editorTab = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(editorTab == tab ? .black : .white.opacity(0.52))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(editorTab == tab ? .white : .clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.white.opacity(0.07))
        .clipShape(Capsule())
    }

    private var musicEditor: some View {
        VStack(spacing: 10) {
            VStack(spacing: 8) {
                ForEach(MusicTrack.all) { track in
                    Button {
                        selectedMusicID = track.id
                        Task { await renderPreview() }
                    } label: {
                        HStack(spacing: 12) {
                            Text(track.displayName)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                            Spacer()
                            if selectedMusicID == track.id {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 9, height: 9)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(.white.opacity(selectedMusicID == track.id ? 0.13 : 0.055))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            volumeSlider(
                title: "音楽",
                value: Binding(
                    get: { musicVolume },
                    set: { musicVolume = $0 }
                ),
                onCommit: { Task { await renderPreview() } }
            )
        }
    }

    private var clipsEditor: some View {
        VStack(spacing: 12) {
            ForEach(selectedMoments) { moment in
                clipEditorCard(moment: moment)
            }
        }
    }

    private func clipEditorCard(moment: CaptureMoment) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    if let url = moment.clipURL {
                        VideoThumbnailView(url: url)
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
                .frame(width: 104, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text(moment.captureTimeLabel)
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)

                    TextField(
                        "",
                        text: Binding(
                            get: { clipTexts[moment.id] ?? "" },
                            set: { value in
                                clipTexts[moment.id] = value
                                schedulePreviewRefresh()
                            }
                        ),
                        prompt: Text("文章を追加").foregroundStyle(.white.opacity(0.25))
                    )
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit { Task { await renderPreview() } }
                }

                Spacer(minLength: 0)
            }

            volumeSlider(
                title: "素材音量",
                value: Binding(
                    get: { clipVolumes[moment.id] ?? 1 },
                    set: { clipVolumes[moment.id] = $0 }
                ),
                onCommit: { Task { await renderPreview() } }
            )
        }
        .padding(14)
        .background(.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .simultaneousGesture(
            TapGesture().onEnded {
                Task { await seekToMoment(moment) }
            }
        )
    }

    private func volumeSlider(title: String, value: Binding<Double>, onCommit: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.48))
                Spacer()
                Text("\(Int(value.wrappedValue * 100))")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.36))
            }
            Slider(value: value, in: 0...1) { editing in
                if !editing { onCommit() }
            }
            .tint(.white)
        }
    }

    private func bottomAction(
        title: String,
        disabled: Bool,
        progress: Double? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(disabled ? .white.opacity(0.35) : .black)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(disabled ? .white.opacity(0.1) : .white)
                .clipShape(Capsule())
                .overlay {
                    if let progress {
                        SavingProgressBorder(progress: progress)
                            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func renderPreview() async {
        guard !selectedMoments.isEmpty, !isRendering else { return }
        isRendering = true
        let resumeTime = previewCurrentTime
        let nextItem = await store.makeArchivePreviewItem(
            moments: selectedMomentsForRender,
            musicID: selectedMusicID,
            musicVolume: musicVolume,
            clipVolumes: clipVolumes
        )
        if let nextItem {
            let nextTimeline = await makeClipTimeline()
            clipTimeline = nextTimeline
            previewItem = nextItem
            previewPlayer.replaceCurrentItem(with: nextItem)
            previewPlayer.pause()
            let maxTime = nextTimeline.last?.end ?? previewDuration
            let nextTime = min(resumeTime, max(maxTime, 0))
            await previewPlayer.seek(
                to: CMTime(seconds: nextTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            previewCurrentTime = nextTime
            isPreviewPlaying = false
            showsPreviewControls = true
        }
        isRendering = false
    }

    private func saveArchive() async {
        guard !selectedMoments.isEmpty, !isSaving else { return }
        AppHaptics.light()
        isSaving = true
        saveProgress = 0
        if let _ = await store.saveArchive(
            moments: selectedMomentsForRender,
            musicID: selectedMusicID,
            musicVolume: musicVolume,
            clipVolumes: clipVolumes,
            progressHandler: { progress in
                saveProgress = progress
            }
        ) {
            didSave = true
            AppHaptics.success()
            dismiss()
        }
        isSaving = false
        saveProgress = 0
    }

    private func prepareEditor() {
        for moment in selectedMoments where clipVolumes[moment.id] == nil {
            clipVolumes[moment.id] = 1
        }
        for moment in selectedMoments where clipTexts[moment.id] == nil {
            clipTexts[moment.id] = moment.customText ?? ""
        }
    }

    private var selectedMomentsForRender: [CaptureMoment] {
        selectedMoments.map { moment in
            var copy = moment
            let text = clipTexts[moment.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.customText = (text?.isEmpty ?? true) ? nil : text
            return copy
        }
    }

    private func schedulePreviewRefresh() {
        previewRefreshTask?.cancel()
        previewRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await renderPreview()
        }
    }

    private func togglePreviewPlayback() {
        if previewPlayer.rate > 0 {
            previewPlayer.pause()
            isPreviewPlaying = false
            return
        }

        if previewDuration > 0, previewCurrentTime >= previewDuration - 0.1 {
            seekPreview(to: 0)
        }
        previewPlayer.play()
        isPreviewPlaying = true
        showsPreviewControls = true
    }

    private func seekPreview(to seconds: Double) {
        let clamped = min(max(seconds, 0), max(previewDuration, 0))
        previewCurrentTime = clamped
        Task {
            await previewPlayer.seek(
                to: CMTime(seconds: clamped, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }

    private func seekToMoment(_ target: CaptureMoment) async {
        if let entry = clipTimeline.first(where: { $0.id == target.id }) {
            seekPreview(to: entry.start)
            return
        }

        var offset = 0.0
        for moment in selectedMomentsForRender {
            if moment.id == target.id {
                seekPreview(to: offset)
                return
            }
            guard let url = moment.clipURL else { continue }
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(duration)
                if seconds.isFinite { offset += max(seconds, 0) }
            }
        }
    }

    private func makeClipTimeline() async -> [ArchiveClipTimelineEntry] {
        var offset = 0.0
        var entries: [ArchiveClipTimelineEntry] = []
        for moment in selectedMomentsForRender {
            guard let url = moment.clipURL else { continue }
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            let safeDuration = duration.isFinite ? max(duration, 0) : 0
            entries.append(ArchiveClipTimelineEntry(id: moment.id, start: offset, end: offset + safeDuration))
            offset += safeDuration
        }
        return entries
    }

    private func monitorPreviewPlayback() async {
        while !Task.isCancelled {
            let current = CMTimeGetSeconds(previewPlayer.currentTime())
            if current.isFinite {
                previewCurrentTime = max(current, 0)
            }

            if let duration = previewPlayer.currentItem?.duration {
                let seconds = CMTimeGetSeconds(duration)
                if seconds.isFinite {
                    previewDuration = max(seconds, 0)
                }
            }

            isPreviewPlaying = previewPlayer.rate > 0.01
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func archiveDateTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }
}

private enum ArchiveComposerStep {
    case select
    case preview
}

private enum ArchiveComposerTab: CaseIterable {
    case music
    case clips

    var title: String {
        switch self {
        case .music: "音楽"
        case .clips: "クリップ"
        }
    }
}

private struct SavingProgressBorder: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 1.5
        let rect = rect.insetBy(dx: inset, dy: inset)
        let radius = min(rect.height / 2, rect.width / 2)
        let clampedProgress = min(max(progress, 0), 1)

        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))

        return path.trimmedPath(from: 0, to: clampedProgress)
    }
}

private struct ArchiveSourceGroup: Identifiable {
    var id: Date { date }
    let date: Date
    let title: String
    let moments: [CaptureMoment]
}

private struct ArchiveClipTimelineEntry: Identifiable {
    var id: UUID
    let start: Double
    let end: Double
}

struct ArchiveSourceCard: View {
    let moment: CaptureMoment
    let isSelected: Bool

    var body: some View {
        ZStack {
            if let url = moment.clipURL {
                VideoThumbnailView(url: url)
            } else {
                Color.white.opacity(0.08)
            }

            Text(moment.captureTimeLabel)
                .font(.system(size: 30, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.58), radius: 8, y: 3)

            VStack {
                HStack {
                    Spacer()
                    Image(systemName: isSelected ? "checkmark" : "plus")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(isSelected ? .black : .white)
                        .frame(width: 32, height: 32)
                        .background(isSelected ? .white : .black.opacity(0.54))
                        .clipShape(Circle())
                        .padding(9)
                }
                Spacer()
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? .white : .white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        )
    }
}

struct ArchivePreviewPlayer: View {
    let player: AVPlayer

    var body: some View {
        PlayerLayerView(player: player)
            .onDisappear { player.pause() }
    }
}

struct ArchivePreviewControls: View {
    let isPlaying: Bool
    let currentTime: Double
    let duration: Double
    var includesFullscreen = false
    let onTogglePlay: () -> Void
    let onSeek: (Double) -> Void
    var onFullscreen: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onTogglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Text(timeLabel(currentTime))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 38, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { duration > 0 ? min(currentTime, duration) : 0 },
                    set: { onSeek($0) }
                ),
                in: 0...max(duration, 0.01)
            )
            .tint(.white)

            Text(timeLabel(duration))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.46))
                .frame(width: 38, alignment: .leading)

            if includesFullscreen {
                Button {
                    onFullscreen?()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.62))
        .clipShape(Capsule())
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(Int(seconds.rounded(.down)), 0)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

struct ArchiveFullscreenPreviewView: View {
    let player: AVPlayer
    let isPlaying: Bool
    let currentTime: Double
    let duration: Double
    let moment: CaptureMoment?
    @Binding var showsControls: Bool
    let onDismiss: () -> Void
    let onTogglePlay: () -> Void
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let previewWidth = proxy.size.width
            let previewHeight = previewWidth * 9 / 16

            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    ZStack {
                        ArchivePreviewPlayer(player: player)

                        if let moment {
                            previewTextOverlay(moment: moment)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: previewWidth, height: previewHeight)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            showsControls.toggle()
                        }
                    }

                    Spacer()
                }

                VStack {
                    HStack {
                        Spacer()
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .background(.black.opacity(0.56))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 18)
                        .padding(.top, 18)
                        .opacity(showsControls ? 1 : 0)
                    }

                    Spacer()

                    if showsControls {
                        ArchivePreviewControls(
                            isPlaying: isPlaying,
                            currentTime: currentTime,
                            duration: duration,
                            onTogglePlay: onTogglePlay,
                            onSeek: onSeek
                        )
                        .padding(.horizontal, 18)
                        .padding(.bottom, 24)
                        .transition(.opacity)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func previewTextOverlay(moment: CaptureMoment) -> some View {
        VStack(spacing: 6) {
            Text(moment.captureTimeLabel)
                .font(.system(size: 44, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.65), radius: 10, y: 3)

            if let text = moment.customText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                Text(text)
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.62), radius: 8, y: 2)
                    .padding(.horizontal, 28)
            }
        }
        .padding(.bottom, 26)
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerSurfaceView, context: Context) {
        uiView.playerLayer.player = player
    }
}

private final class PlayerSurfaceView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

struct DeleteConfirmPopup: View {
    let title: String
    let message: String
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.68)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.white)
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                }

                HStack(spacing: 10) {
                    Button(action: onCancel) {
                        Text("キャンセル")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(.white.opacity(0.08))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: onDelete) {
                        Text("削除")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
            .background(.black.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
            .padding(.horizontal, 28)
        }
    }
}

// MARK: - Helpers

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}
