import AVFoundation
import AVKit
import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject private var store: PulseStore

    private let gridColumns = [
        GridItem(.flexible(), spacing: 5),
        GridItem(.flexible(), spacing: 5),
        GridItem(.flexible(), spacing: 5),
        GridItem(.flexible(), spacing: 5)
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

                    if store.isComposing {
                        composingBanner
                            .padding(.horizontal, 22)
                            .padding(.top, 16)
                    }

                    if let url = store.plan.vlogURL {
                        vlogCard(url: url)
                            .padding(.horizontal, 22)
                            .padding(.top, 20)
                    }

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

                    Color.clear.frame(height: 140)
                }
            }

            captureButtonArea
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $store.showingCapture) {
            CaptureMomentView(moment: activeMoment)
                .environmentObject(store)
        }
    }

    // MARK: - Active Moment

    private var activeMoment: CaptureMoment {
        if let id = store.selectedMomentID,
           let m = store.plan.moments.first(where: { $0.id == id }) { return m }
        return store.plan.moments.first(where: { $0.status == .scheduled })
            ?? store.plan.moments.last
            ?? CaptureMoment(id: UUID(), scheduledAt: Date(), clipPath: nil, status: .scheduled)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PULSE")
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
            ZStack {
                Circle()
                    .fill(.white.opacity(0.07))
                    .frame(width: 56, height: 56)
                VStack(spacing: 1) {
                    Text("\(store.plan.capturedCount)")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Text("/ 11")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .onLongPressGesture {
                Task { await store.scheduleToday() }
            }
        }
    }

    // MARK: - Progress Strip

    private var progressStrip: some View {
        HStack(spacing: 4) {
            ForEach(0..<11, id: \.self) { i in
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
            ForEach(Array(store.plan.moments.enumerated()), id: \.element.id) { index, moment in
                ClipSlotView(moment: moment, index: index)
                    .aspectRatio(3/4, contentMode: .fit)
                    .onTapGesture {
                        guard moment.status == .scheduled else { return }
                        store.selectedMomentID = moment.id
                        store.showingCapture = true
                    }
            }
        }
    }

    // MARK: - Vlog Card

    private func vlogCard(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("TODAY'S VLOG", systemImage: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .kerning(1.5)
                Spacer()
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            VideoPlayer(player: AVPlayer(url: url))
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(16)
        .background(.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        )
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

    // MARK: - Capture Button

    private var captureButtonArea: some View {
        VStack(spacing: 8) {
            if store.plan.capturedCount < 11 {
                Button {
                    store.selectedMomentID = nil
                    store.showingCapture = true
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.2), lineWidth: 4)
                            .frame(width: 84, height: 84)
                        Circle()
                            .fill(.white)
                            .frame(width: 72, height: 72)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.black)
                    }
                }
                .accessibilityLabel("2秒撮影")
            }
            Text(footerLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.bottom, 38)
    }

    private var footerLabel: String {
        if store.plan.capturedCount == 11 { return "全部撮れた！" }
        if let next = store.plan.moments.first(where: { $0.status == .scheduled }) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return "次は \(f.string(from: next.scheduledAt))"
        }
        return "\(store.plan.capturedCount) / 11"
    }
}

// MARK: - ClipSlotView

struct ClipSlotView: View {
    let moment: CaptureMoment
    let index: Int

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let url = moment.clipURL {
                VideoThumbnailView(url: url)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .black))
                            .foregroundStyle(.black)
                            .padding(3.5)
                            .background(Circle().fill(.white))
                            .padding(5)
                    }
            } else {
                Color.white.opacity(moment.status == .scheduled ? 0.07 : 0.03)
                    .overlay {
                        Text(moment.scheduledAt, style: .time)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.28))
                    }
            }

            Text("\(index + 1)")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 5)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(.black.opacity(0.5)))
                .padding(5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - VideoThumbnailView

struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
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
            thumbnail = await makeThumbnail(from: url)
        }
    }

    private func makeThumbnail(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 300, height: 400)
        guard let cgImg = try? await gen.image(at: .zero).image else { return nil }
        return UIImage(cgImage: cgImg)
    }
}

#Preview {
    ContentView()
        .environmentObject(PulseStore())
}
