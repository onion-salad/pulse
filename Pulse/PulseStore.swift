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

    private let scheduler = NotificationScheduler()
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
        refreshVlogs()
        Task { await removePortraitVlogs() }

        if let data = try? Data(contentsOf: planURL),
           let saved = try? JSONDecoder().decode(DayPlan.self, from: data) {
            let todayKey = Self.dateKey(for: Date())

            if saved.dateKey == todayKey {
                plan = saved
                if plan.capturedCount > 0 && plan.vlogPath == nil && !isComposing {
                    Task { await composeVlog() }
                }
            } else {
                let previous = saved
                Task { await composeLeftover(plan: previous) }
                plan = Self.makePlan(for: Date())
                save()
                Task { await scheduleToday() }
            }
        } else {
            plan = Self.makePlan(for: Date())
            save()
            Task { await scheduleToday() }
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

    private func composeLeftover(plan: DayPlan) async {
        guard plan.capturedCount > 0, plan.vlogPath == nil else { return }
        let output = storageURL.appendingPathComponent("vlog-\(plan.dateKey).mp4")
        guard !FileManager.default.fileExists(atPath: output.path) else { return }
        let captured = plan.moments.filter { $0.status == .captured }
        guard !captured.isEmpty else { return }
        let musicID = plan.selectedMusicID ?? MusicTrack.defaultFor(dateKey: plan.dateKey).id
        _ = try? await composer.compose(moments: captured, outputURL: output, musicID: musicID)
        await MainActor.run { refreshVlogs() }
    }

    // MARK: - Schedule

    func scheduleToday() async {
        do {
            let granted = try await scheduler.requestPermission()
            guard granted else {
                permissionMessage = "通知がオフです。Settingsで通知を許可すると、撮影タイミングのお知らせが届きます。"
                return
            }
            if plan.dateKey != Self.dateKey(for: Date()) || plan.moments.isEmpty {
                plan = Self.makePlan(for: Date())
                save()
            }
            try await scheduler.schedule(moments: plan.moments)
            permissionMessage = nil
        } catch {
            permissionMessage = error.localizedDescription
        }
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
        if plan.capturedCount == plan.totalSlots && plan.vlogPath == nil && !isComposing {
            Task { await composeVlog() }
        }
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

    var activeHourlyMoment: CaptureMoment? {
        let now = Date()
        return plan.moments.first { $0.kind == .hourly && $0.status == .scheduled && $0.isWithinCaptureWindow(now: now) }
    }

    var availableFreeMoment: CaptureMoment? {
        plan.moments.first { $0.kind == .free && $0.status == .scheduled }
    }

    /// Camera page: active hourly window first, then free slot.
    var momentForCameraPage: CaptureMoment? {
        activeHourlyMoment ?? availableFreeMoment
    }

    func prepareCameraMoment() -> CaptureMoment {
        if let selectedMomentID,
           let selected = plan.moments.first(where: { $0.id == selectedMomentID && $0.status == .scheduled }) {
            return selected
        }
        if let activeHourlyMoment { return activeHourlyMoment }
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
        Task { await composeVlog() }
    }

    func deleteVlog(url: URL) {
        try? FileManager.default.removeItem(at: url)
        if url.lastPathComponent == "vlog-\(plan.dateKey).mp4" {
            plan.vlogPath = nil
            save()
        }
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

    // MARK: - Plan generation

    private static func makePlan(for date: Date) -> DayPlan {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)

        var hourlyMoments: [CaptureMoment] = []
        for hour in 7...23 {
            guard let slot = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dayStart) else { continue }
            if slot.addingTimeInterval(5 * 60) < date { continue }
            hourlyMoments.append(CaptureMoment(
                id: UUID(), scheduledAt: slot, clipPath: nil, status: .scheduled,
                kind: .hourly, customText: nil, retakeCount: 0, capturedAt: nil
            ))
        }

        let free = CaptureMoment(
            id: UUID(), scheduledAt: dayStart, clipPath: nil, status: .scheduled,
            kind: .free, customText: nil, retakeCount: 0, capturedAt: nil
        )

        return DayPlan(dateKey: dateKey(for: date), moments: hourlyMoments + [free], vlogPath: nil, selectedMusicID: nil)
    }

    private static func dateKey(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
