import AVKit
import SwiftUI

struct DebugView: View {
    @EnvironmentObject private var store: PulseStore

    @State private var isGenerating = false
    @State private var progress: Double = 0
    @State private var statusMessage: String?

    private let generator = TestVideoGenerator()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, 22)
                        .padding(.top, 16)

                    composerLogicSection
                        .padding(.horizontal, 22)
                        .padding(.top, 28)

                    testSection
                        .padding(.horizontal, 22)
                        .padding(.top, 28)

                    if store.plan.capturedCount > 0 {
                        clipGridSection
                            .padding(.horizontal, 22)
                            .padding(.top, 28)
                    }

                    Color.clear.frame(height: 60)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("DEV")
                    .font(.system(size: 32, weight: .black))
                    .foregroundStyle(.white)
                    .kerning(5)
                Text("DEBUG")
                    .font(.system(size: 32, weight: .black))
                    .foregroundStyle(.yellow)
                    .kerning(3)
            }
            Text("Development & test tools")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .kerning(1.5)
        }
    }

    // MARK: - VlogComposer Logic

    private var composerLogicSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("VLOGCOMPOSER LOGIC")

            VStack(alignment: .leading, spacing: 10) {
                logRow("1", "11本のクリップをAVMutableCompositionに時系列で結合")
                logRow("2", "各クリップのpreferredTransformを読み込み（縦向き情報を保持）")
                logRow("3", "isRotated90フラグで視覚的なvisualSizeを判定")
                logRow("4", "出力サイズ 1080×1920（9:16）に対してfitTransformを計算")
                logRow("5", "AVMutableVideoCompositionで各クリップに変換を適用")
                logRow("6", "HighestQualityプリセットでMP4に書き出し")
                logRow("7", "トリガー: 11枚目撮影直後 or 翌日アプリ起動時")
            }
            .padding(16)
            .background(.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.07), lineWidth: 1)
            )
        }
    }

    private func logRow(_ num: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(num)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.yellow.opacity(0.7))
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Test Content

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("TEST CONTENT")

            if isGenerating {
                VStack(spacing: 8) {
                    ProgressView(value: progress, total: 1.0)
                        .tint(.yellow)
                    Text(statusMessage ?? "生成中...")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(14)
                .background(.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if let msg = statusMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(.green.opacity(0.8))
                    .padding(.horizontal, 4)
            }

            // Generate button
            Button {
                Task { await runGenerate() }
            } label: {
                Label(
                    isGenerating ? "生成中..." : "11本のテスト動画を生成してvlogを作る",
                    systemImage: "play.rectangle.fill"
                )
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(isGenerating ? Color.yellow.opacity(0.5) : Color.yellow)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(isGenerating || store.isComposing)

            if store.plan.capturedCount > 0 && !isGenerating {
                Button {
                    store.clearForDebug()
                    statusMessage = nil
                } label: {
                    Label("テストデータをクリア", systemImage: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.red.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    // MARK: - Clip Grid

    private var clipGridSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("TODAY'S CLIPS  \(store.plan.capturedCount)/11")

            let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(Array(store.plan.moments.enumerated()), id: \.element.id) { i, moment in
                    ZStack(alignment: .bottom) {
                        if let url = moment.clipURL {
                            VideoThumbnailView(url: url)
                        } else {
                            Color.white.opacity(0.05)
                        }
                        Text("#\(i + 1)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.bottom, 4)
                    }
                    .aspectRatio(9/16, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            if store.isComposing {
                HStack(spacing: 8) {
                    ProgressView().tint(.yellow).scaleEffect(0.7)
                    Text("vlog生成中…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            if let url = store.plan.vlogURL {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("COMPOSED VLOG")
                    VideoPlayer(player: AVPlayer(url: url))
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.3))
            .kerning(2)
    }

    private func runGenerate() async {
        isGenerating = true
        progress = 0
        statusMessage = nil

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("PulseClips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var moments: [CaptureMoment] = []
        let base = Date().addingTimeInterval(-Double(11) * 3600)

        for i in 0..<11 {
            await MainActor.run { statusMessage = "Clip \(i + 1) / 11 を生成中…" }

            let moment = CaptureMoment(
                id: UUID(),
                scheduledAt: base.addingTimeInterval(Double(i) * 3600),
                clipPath: nil,
                status: .scheduled
            )
            let url = dir.appendingPathComponent("\(moment.id.uuidString).mov")

            if let _ = try? await generator.generateClip(number: i + 1, outputURL: url) {
                var captured = moment
                captured.clipPath = url.path
                captured.status = .captured
                moments.append(captured)
            } else {
                moments.append(moment)
            }

            await MainActor.run { progress = Double(i + 1) / 11.0 }
        }

        await MainActor.run {
            store.loadTestMoments(moments)
            isGenerating = false
            statusMessage = "✓ 11本生成完了。vlog合成中…"
        }

        await store.composeVlog()

        await MainActor.run { statusMessage = "✓ 完了！" }
    }
}
