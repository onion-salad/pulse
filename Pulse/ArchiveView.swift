import AVFoundation
import AVKit
import SwiftUI

// MARK: - ArchiveView

struct ArchiveView: View {
    @EnvironmentObject private var store: PulseStore
    @State private var selectedVlog: IdentifiableURL?

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if store.allVlogs.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                            .padding(.horizontal, 22)
                            .padding(.top, 16)

                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(store.allVlogs, id: \.absoluteString) { url in
                                VlogCardView(url: url)
                                    .onTapGesture { selectedVlog = IdentifiableURL(url: url) }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 20)

                        Color.clear.frame(height: 50)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $selectedVlog) { item in
            VlogPlayerView(url: item.url)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ARCHIVE")
                .font(.system(size: 32, weight: .black))
                .foregroundStyle(.white)
                .kerning(5)
            Text("\(store.allVlogs.count) day\(store.allVlogs.count == 1 ? "" : "s") captured")
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
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
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
        }
        .aspectRatio(9/16, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: url) { thumbnail = await makeThumbnail() }
    }

    private var dateLabel: String {
        let stem = url.deletingPathExtension().lastPathComponent
        let dateStr = stem.replacingOccurrences(of: "vlog-", with: "")
        let parse = DateFormatter(); parse.dateFormat = "yyyy-MM-dd"; parse.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parse.date(from: dateStr) else { return dateStr }
        let display = DateFormatter(); display.dateFormat = "MMM d"; display.locale = Locale(identifier: "en_US")
        return display.string(from: date).uppercased()
    }

    private func makeThumbnail() async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 400, height: 700)
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
        let dateStr = stem.replacingOccurrences(of: "vlog-", with: "")
        let parse = DateFormatter(); parse.dateFormat = "yyyy-MM-dd"; parse.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parse.date(from: dateStr) else { return dateStr }
        let display = DateFormatter(); display.dateFormat = "EEEE, MMMM d"; display.locale = Locale(identifier: "en_US")
        return display.string(from: date)
    }
}

// MARK: - Helpers

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}
