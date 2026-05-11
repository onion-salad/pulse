import AVFoundation
import Foundation
import UserNotifications

@MainActor
final class PulseStore: ObservableObject {
    @Published private(set) var plan: DayPlan
    @Published var showingCapture = false
    @Published var selectedMomentID: UUID?
    @Published var isComposing = false
    @Published var permissionMessage: String?
    @Published private(set) var vlogs: [URL] = []

    private let composer = VlogComposer()
    private let storageURL: URL
    private let planURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storageURL = documents.appendingPathComponent("PulseClips", isDirectory: true)
        planURL = documents.appendingPathComponent("pulse-day-plan.json")
        plan = DayPlan(dateKey: Self.dateKey(for: Date()), moments: [], vlogPath: nil)
    }

    // MARK: - Lifecycle

    func load() {
        try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        refreshVlogs()
        Task { await removePortraitVlogs() }

        if let data = try? Data(contentsOf: planURL),
           let decoded = try? JSONDecoder().decode(DayPlan.self, from: data) {
            let saved = repairStoredMediaPaths(decoded)
            let todayKey = Self.dateKey(for: Date())

            if saved.dateKey == todayKey {
                plan = Self.normalizeAnytimePlan(saved, for: Date())
                save()
            } else {
                plan = Self.makePlan(for: Date())
                save()
            }
        } else {
            plan = Self.makePlan(for: Date())
            save()
        }
    }

    func refreshVlogs() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storageURL, includingPropertiesForKeys: nil
        ) else { vlogs = []; return }
        vlogs = files
            .filter { $0.lastPathComponent.hasPrefix("vlog-") && $0.pathExtension == "mp4" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func removePortraitVlogs() async {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storageURL, includingPropertiesForKeys: nil
        ) else { return }

        for url in files where url.lastPathComponent.hasPrefix("vlog-") && url.pathExtension == "mp4" {
            if await isPortraitVideo(url: url) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        refreshVlogs()
    }

    private func isPortraitVideo(url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let video = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await video.load(.naturalSize),
              let transform = try? await video.load(.preferredTransform) else {
            return false
        }
        let isRotated = abs(transform.b) > 0.5
        let visualSize = isRotated
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize
        return visualSize.height > visualSize.width
    }

    // MARK: - Notification / URL

    func openCaptureFromNotification(momentID: String?) {
        if let momentID, let id = UUID(uuidString: momentID) { selectedMomentID = id }
        showingCapture = true
    }

    func handle(url: URL) {
        if url.host == "capture" { selectedMomentID = nil; showingCapture = true }
    }

    // MARK: - Clip helpers

    func clipURL(for moment: CaptureMoment) -> URL {
        storageURL.appendingPathComponent("\(moment.id.uuidString).mov")
    }

    func tempClipURL(for moment: CaptureMoment) -> URL {
        storageURL.appendingPathComponent("temp-\(moment.id.uuidString).mov")
    }

    // MARK: - Capture

    func registerCapture(momentID: UUID, url: URL, capturedAt: Date = Date()) {
        guard let index = plan.moments.firstIndex(where: { $0.id == momentID }) else { return }
        plan.moments[index].clipPath = url.path
        plan.moments[index].status = .captured
        plan.moments[index].capturedAt = capturedAt
        save()
    }

    func incrementRetake(for momentID: UUID) {
        guard let index = plan.moments.firstIndex(where: { $0.id == momentID }) else { return }
        plan.moments[index].retakeCount += 1
        save()
    }

    func setCustomText(_ text: String?, for momentID: UUID) {
        guard let index = plan.moments.firstIndex(where: { $0.id == momentID }) else { return }
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        plan.moments[index].customText = (t?.isEmpty ?? true) ? nil : t
        save()
    }

    // MARK: - Active moment helpers

    var availableFreeMoment: CaptureMoment? {
        plan.moments.first { $0.kind == .free && $0.status == .scheduled }
    }

    /// Camera page: always uses the next free anytime slot.
    var momentForCameraPage: CaptureMoment? {
        availableFreeMoment
    }

    func prepareCameraMoment() -> CaptureMoment {
        if let selectedMomentID,
           let selected = plan.moments.first(where: { $0.id == selectedMomentID && $0.status == .scheduled }) {
            return selected
        }
        if let availableFreeMoment { return availableFreeMoment }

        let moment = CaptureMoment(
            id: UUID(),
            scheduledAt: Date(),
            clipPath: nil,
            status: .scheduled,
            kind: .free,
            customText: nil,
            retakeCount: 0,
            capturedAt: nil
        )
        plan.moments.append(moment)
        save()
        return moment
    }

    var selectedMusicTrack: MusicTrack {
        MusicTrack.track(for: plan.selectedMusicID) ?? MusicTrack.defaultFor(dateKey: plan.dateKey)
    }

    // MARK: - Vlog

    var archiveSourceMoments: [CaptureMoment] {
        let planned = plan.moments
            .filter { $0.status == .captured && $0.clipURL != nil }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storageURL,
            includingPropertiesForKeys: [.creationDateKey]
        ) else {
            return planned.sorted { ($0.capturedAt ?? $0.scheduledAt) < ($1.capturedAt ?? $1.scheduledAt) }
        }

        var momentsByFile = Dictionary(uniqueKeysWithValues: planned.compactMap { moment -> (String, CaptureMoment)? in
            guard let filename = moment.clipURL?.lastPathComponent else { return nil }
            return (filename, moment)
        })

        for url in files where url.pathExtension == "mov" && !url.lastPathComponent.hasPrefix("temp-") {
            if momentsByFile[url.lastPathComponent] != nil { continue }

            let values = try? url.resourceValues(forKeys: [.creationDateKey])
            let createdAt = values?.creationDate ?? Date()
            let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
            momentsByFile[url.lastPathComponent] = CaptureMoment(
                id: id,
                scheduledAt: createdAt,
                clipPath: url.path,
                status: .captured,
                kind: .free,
                customText: nil,
                retakeCount: 0,
                capturedAt: createdAt
            )
        }

        return momentsByFile.values.sorted {
            ($0.capturedAt ?? $0.scheduledAt) < ($1.capturedAt ?? $1.scheduledAt)
        }
    }

    func makeArchivePreviewItem(
        moments: [CaptureMoment],
        musicID: String,
        musicVolume: Double,
        clipVolumes: [UUID: Double]
    ) async -> AVPlayerItem? {
        guard !moments.isEmpty else { return nil }

        do {
            let normalizedClipVolumes = clipVolumes.reduce(into: [UUID: Float]()) { result, item in
                result[item.key] = Float(item.value)
            }
            return try await composer.makePlayerItem(
                moments: moments,
                musicID: musicID,
                musicVolume: Float(musicVolume),
                clipVolumes: normalizedClipVolumes
            )
        } catch {
            permissionMessage = "プレビュー作成に失敗しました: \(error.localizedDescription)"
            return nil
        }
    }

    func saveArchive(
        moments: [CaptureMoment],
        musicID: String,
        musicVolume: Double,
        clipVolumes: [UUID: Double],
        progressHandler: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async -> URL? {
        guard !moments.isEmpty else { return nil }
        isComposing = true
        defer { isComposing = false }

        let output = storageURL.appendingPathComponent("vlog-\(Self.archiveTimestamp()).mp4")
        try? FileManager.default.removeItem(at: output)

        do {
            let normalizedClipVolumes = clipVolumes.reduce(into: [UUID: Float]()) { result, item in
                result[item.key] = Float(item.value)
            }
            let url = try await composer.compose(
                moments: moments,
                outputURL: output,
                musicID: musicID,
                musicVolume: Float(musicVolume),
                clipVolumes: normalizedClipVolumes,
                progressHandler: progressHandler
            )
            refreshVlogs()
            return url
        } catch {
            permissionMessage = "アーカイブ保存に失敗しました: \(error.localizedDescription)"
            return nil
        }
    }

    func saveArchivePreview(_ previewURL: URL) -> URL? {
        let output = storageURL.appendingPathComponent("vlog-\(Self.archiveTimestamp()).mp4")
        try? FileManager.default.removeItem(at: output)

        do {
            try FileManager.default.moveItem(at: previewURL, to: output)
            refreshVlogs()
            return output
        } catch {
            permissionMessage = "アーカイブ保存に失敗しました: \(error.localizedDescription)"
            return nil
        }
    }

    func discardArchivePreview(_ previewURL: URL?) {
        guard let previewURL else { return }
        if previewURL.lastPathComponent.hasPrefix("preview-") {
            try? FileManager.default.removeItem(at: previewURL)
        }
    }

    func composeVlog() async {
        let captured = plan.moments.filter { $0.status == .captured }
        guard !captured.isEmpty else { return }
        isComposing = true
        defer { isComposing = false }
        do {
            let output = storageURL.appendingPathComponent("vlog-\(plan.dateKey).mp4")
            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            let musicID = plan.selectedMusicID ?? MusicTrack.defaultFor(dateKey: plan.dateKey).id
            let url = try await composer.compose(moments: captured, outputURL: output, musicID: musicID)
            plan.vlogPath = url.path
            save()
            refreshVlogs()
        } catch {
            permissionMessage = "ショート生成に失敗しました: \(error.localizedDescription)"
        }
    }

    func setVlogMusic(_ musicID: String) {
        plan.selectedMusicID = musicID
        save()
    }

    func deleteVlog(url: URL) {
        try? FileManager.default.removeItem(at: url)
        if url.lastPathComponent == "vlog-\(plan.dateKey).mp4" {
            plan.vlogPath = nil
            save()
        }
        refreshVlogs()
    }

    func deleteCapture(momentID: UUID) {
        guard let index = plan.moments.firstIndex(where: { $0.id == momentID }) else { return }

        if let clipPath = plan.moments[index].clipPath,
           let clipURL = resolvedStoredURL(path: clipPath) {
            try? FileManager.default.removeItem(at: clipURL)
        }

        plan.moments.remove(at: index)
        ensureFreeSlot()
        deleteCurrentVlogFile()
        save()
        refreshVlogs()
    }

    func clearForDebug() {
        plan = Self.makePlan(for: Date())
        save()
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(plan) else { return }
        try? data.write(to: planURL, options: [.atomic])
    }

    private func repairStoredMediaPaths(_ saved: DayPlan) -> DayPlan {
        var repaired = saved

        for index in repaired.moments.indices {
            guard let clipPath = repaired.moments[index].clipPath else { continue }
            if let url = resolvedStoredURL(path: clipPath) {
                repaired.moments[index].clipPath = url.path
            } else {
                repaired.moments[index].clipPath = nil
                repaired.moments[index].status = .missed
            }
        }

        if let vlogPath = repaired.vlogPath,
           let url = resolvedStoredURL(path: vlogPath) {
            repaired.vlogPath = url.path
        } else if repaired.vlogPath != nil {
            repaired.vlogPath = nil
        }

        return repaired
    }

    private func resolvedStoredURL(path: String) -> URL? {
        let storedURL = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: storedURL.path) {
            return storedURL
        }

        let fallbackURL = storageURL.appendingPathComponent(storedURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: fallbackURL.path) {
            return fallbackURL
        }

        return nil
    }

    private func deleteCurrentVlogFile() {
        if let vlogPath = plan.vlogPath,
           let url = resolvedStoredURL(path: vlogPath) {
            try? FileManager.default.removeItem(at: url)
        }
        let expectedURL = storageURL.appendingPathComponent("vlog-\(plan.dateKey).mp4")
        if FileManager.default.fileExists(atPath: expectedURL.path) {
            try? FileManager.default.removeItem(at: expectedURL)
        }
        plan.vlogPath = nil
    }

    private func ensureFreeSlot() {
        if plan.moments.contains(where: { $0.status == .scheduled && $0.kind == .free }) { return }
        plan.moments.append(CaptureMoment(
            id: UUID(), scheduledAt: Date(), clipPath: nil, status: .scheduled,
            kind: .free, customText: nil, retakeCount: 0, capturedAt: nil
        ))
    }

    // MARK: - Plan generation

    private static func makePlan(for date: Date) -> DayPlan {
        let free = CaptureMoment(
            id: UUID(), scheduledAt: date, clipPath: nil, status: .scheduled,
            kind: .free, customText: nil, retakeCount: 0, capturedAt: nil
        )

        return DayPlan(dateKey: dateKey(for: date), moments: [free], vlogPath: nil, selectedMusicID: nil)
    }

    private static func normalizeAnytimePlan(_ saved: DayPlan, for date: Date) -> DayPlan {
        var plan = saved
        plan.moments = saved.moments.filter { $0.status == .captured }
        if !plan.moments.contains(where: { $0.status == .scheduled && $0.kind == .free }) {
            plan.moments.append(CaptureMoment(
                id: UUID(), scheduledAt: date, clipPath: nil, status: .scheduled,
                kind: .free, customText: nil, retakeCount: 0, capturedAt: nil
            ))
        }
        return plan
    }

    private static func dateKey(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func archiveTimestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}
