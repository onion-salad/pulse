import AVFoundation
import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject private var store: PulseStore
    @State private var pendingDelete: MyVlogDeleteItem?
    @State private var showingComposer = false
    @State private var playingClipID: UUID?

    private let gridColumns = [
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                        .padding(.horizontal, 22)
                        .padding(.top, 16)

                    progressStrip
                        .padding(.horizontal, 22)
                        .padding(.top, 14)

                    clipGrid
                        .padding(.horizontal, 16)
                        .padding(.top, 20)

                    if let msg = store.permissionMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.orange.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                            .padding(.top, 14)
                    }

                    Color.clear.frame(height: 160)
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

            if pendingDelete != nil {
                DeleteConfirmPopup(
                    title: "この素材を削除しますか？",
                    message: "MyVlogから消えます。",
                    onCancel: {
                        pendingDelete = nil
                    },
                    onDelete: {
                        performPendingDelete()
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: pendingDelete != nil)
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showingComposer) {
            ArchiveComposerView(
                initialMomentIDs: Set(visibleMomentRows.map { $0.moment.id }),
                startsInEditor: true
            )
            .environmentObject(store)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MYVLOG")
                    .font(.system(size: 32, weight: .black))
                    .foregroundStyle(.white)
                    .kerning(5)
                Text(Date(), format: .dateTime.weekday(.wide).month().day())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .textCase(.uppercase)
                    .kerning(1.5)
            }
            Spacer()
        }
    }

    // MARK: - Progress Strip

    private var progressStrip: some View {
        let total = max(store.plan.totalSlots, 1)
        return HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i < store.plan.capturedCount ? Color.white : Color.white.opacity(0.12))
                    .frame(height: 3)
                    .animation(.spring(response: 0.35), value: store.plan.capturedCount)
            }
        }
    }

    // MARK: - Clip Grid

    private var clipGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 5) {
            ForEach(visibleMomentRows, id: \.moment.id) { row in
                ClipSlotView(
                    moment: row.moment,
                    index: row.index,
                    isHourlyActive: false,
                    isPlaying: playingClipID == row.moment.id,
                    onDelete: {
                        pendingDelete = .clip(row.moment)
                    }
                )
                .aspectRatio(16/9, contentMode: .fit)
                .onTapGesture {
                    handleSlotTap(moment: row.moment)
                }
            }
        }
    }

    private var visibleMomentRows: [(index: Int, moment: CaptureMoment)] {
        return store.plan.moments.enumerated().compactMap { offset, moment in
            if moment.status == .captured { return (offset, moment) }
            return nil
        }
    }

    private func handleSlotTap(moment: CaptureMoment) {
        if moment.status == .captured, moment.clipURL != nil {
            withAnimation(.easeInOut(duration: 0.16)) {
                playingClipID = playingClipID == moment.id ? nil : moment.id
            }
            return
        }

        guard moment.status == .scheduled else { return }
        store.selectedMomentID = moment.id
        store.showingCapture = true
    }

    // MARK: - Composing Banner

    private var composingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)
                .scaleEffect(0.75)
            Text("ショート生成中…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

}

private extension ContentView {
    func performPendingDelete() {
        switch pendingDelete {
        case .clip(let moment):
            store.deleteCapture(momentID: moment.id)
        case .none:
            break
        }
        pendingDelete = nil
    }
}

private enum MyVlogDeleteItem {
    case clip(CaptureMoment)
}

// MARK: - NoActiveMomentView

struct NoActiveMomentView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.3))
                Text("撮影できるスロットが今はありません")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text("通知が来てから5分以内に撮影できます")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                Button("閉じる") { dismiss() }
                    .padding(.top, 8)
                    .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - ClipSlotView

struct ClipSlotView: View {
    let moment: CaptureMoment
    let index: Int
    let isHourlyActive: Bool
    let isPlaying: Bool
    var onDelete: (() -> Void)?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let url = moment.clipURL {
                Group {
                    if isPlaying {
                        MyVlogInlineClipPlayer(url: url)
                    } else {
                        VideoThumbnailView(url: url)
                    }
                }
                    .overlay {
                        Text(moment.captureTimeLabel)
                            .font(.system(size: 30, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.58), radius: 8, y: 3)
                    }
                    .overlay(alignment: .topTrailing) {
                        if let onDelete {
                            Button {
                                onDelete()
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .background(.black.opacity(0.58))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(5)
                        }
                    }
            } else {
                let baseOpacity: Double = isHourlyActive ? 0.18 : (moment.status == .scheduled ? 0.07 : 0.03)
                ZStack {
                    Color.white.opacity(baseOpacity)
                    if moment.kind == .free {
                        VStack(spacing: 2) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white.opacity(0.65))
                            Text("CAM")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                                .kerning(1)
                        }
                    } else {
                        Text(moment.scheduledAt, style: .time)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(isHourlyActive ? 0.85 : 0.28))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isHourlyActive ? Color.red : .clear, lineWidth: 2)
                )
            }

        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct MyVlogInlineClipPlayer: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                MyVlogPlayerLayer(player: player)
            } else {
                Color.black
            }
        }
        .task(id: url) {
            player?.pause()
            let nextPlayer = AVPlayer(url: url)
            player = nextPlayer
            nextPlayer.play()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let player, notification.object as? AVPlayerItem === player.currentItem else { return }
            player.seek(to: .zero)
            player.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

private struct MyVlogPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> MyVlogPlayerSurfaceView {
        let view = MyVlogPlayerSurfaceView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: MyVlogPlayerSurfaceView, context: Context) {
        uiView.playerLayer.player = player
    }
}

private final class MyVlogPlayerSurfaceView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

extension CaptureMoment {
    var captureTimeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: capturedAt ?? scheduledAt)
    }
}

// MARK: - VideoThumbnailView

struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: UIImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else if didFail {
                Color.white.opacity(0.08)
                    .overlay {
                        Image(systemName: "film")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.28))
                    }
            } else {
                Color.white.opacity(0.1)
                    .overlay {
                        ProgressView()
                            .tint(.white.opacity(0.35))
                            .scaleEffect(0.55)
                    }
            }
        }
        .task(id: url) {
            didFail = false
            thumbnail = await makeThumbnail(from: url)
            didFail = thumbnail == nil
        }
    }

    private func makeThumbnail(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 420, height: 240)
        guard let cgImg = try? await gen.image(at: .zero).image else { return nil }
        return UIImage(cgImage: cgImg).rotatedLeft()
    }
}

extension UIImage {
    func rotatedLeft() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size.height, height: size.width))
        return renderer.image { context in
            let cgContext = context.cgContext
            cgContext.translateBy(x: 0, y: size.width)
            cgContext.rotate(by: -.pi / 2)
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(PulseStore())
}
