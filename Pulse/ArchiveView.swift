import AVFoundation
import AVKit
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
                        ShareLink(item: url) {
                            Image(systemName: "arrow.down.to.line")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(.black.opacity(0.58))
                                .clipShape(Circle())
                        }

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
    @State private var didSave = false
    @State private var didPrepareInitialState = false

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

    @State private var musicVolume = 0.25
    @State private var clipVolumes: [UUID: Double] = [:]

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
            previewPlayer.pause()
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
                    editSectionTitle("MUSIC")

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
                        value: $musicVolume,
                        onCommit: { Task { await renderPreview() } }
                    )

                    editSectionTitle("CLIPS")

                    VStack(spacing: 12) {
                        ForEach(selectedMoments) { moment in
                            clipVolumeControl(moment: moment)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 120)
            }

            bottomAction(title: isSaving ? "保存中" : "アーカイブに保存", disabled: previewItem == nil || isRendering || isSaving) {
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
        }
        .frame(height: 246)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func editSectionTitle(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.white.opacity(0.38))
                .kerning(1.8)
            Spacer()
        }
    }

    private func clipVolumeControl(moment: CaptureMoment) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(moment.captureTimeLabel)
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(Int((clipVolumes[moment.id] ?? 1) * 100))")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
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

    private func bottomAction(title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(disabled ? .white.opacity(0.35) : .black)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(disabled ? .white.opacity(0.1) : .white)
                .clipShape(Capsule())
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func renderPreview() async {
        guard !selectedMoments.isEmpty, !isRendering else { return }
        isRendering = true
        let nextItem = await store.makeArchivePreviewItem(
            moments: selectedMoments,
            musicID: selectedMusicID,
            musicVolume: musicVolume,
            clipVolumes: clipVolumes
        )
        if let nextItem {
            previewItem = nextItem
            previewPlayer.replaceCurrentItem(with: nextItem)
            previewPlayer.play()
        }
        isRendering = false
    }

    private func saveArchive() async {
        guard !selectedMoments.isEmpty, !isSaving else { return }
        isSaving = true
        if let _ = await store.saveArchive(
            moments: selectedMoments,
            musicID: selectedMusicID,
            musicVolume: musicVolume,
            clipVolumes: clipVolumes
        ) {
            didSave = true
            dismiss()
        }
        isSaving = false
    }

    private func prepareEditor() {
        for moment in selectedMoments where clipVolumes[moment.id] == nil {
            clipVolumes[moment.id] = 1
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

private struct ArchiveSourceGroup: Identifiable {
    var id: Date { date }
    let date: Date
    let title: String
    let moments: [CaptureMoment]
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
