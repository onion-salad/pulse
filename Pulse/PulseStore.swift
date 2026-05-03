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

        if let data = try? Data(contentsOf: planURL),
           let saved = try? JSONDecoder().decode(DayPlan.self, from: data) {
            let todayKey = Self.dateKey(for: Date())

            if saved.dateKey == todayKey {
                plan = saved
                if shouldAutoCompose(plan: plan) {
                    Task { await composeVlog() }
                }
            } else {
                // New day: compose any leftover clips from previous days first, then make a fresh plan.
                let previous = saved
                Task {
                    await composeLeftover(plan: previous)
                }
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

    /// Compose a vlog for a finished day's plan if it has clips but no vlog yet.
    private func composeLeftover(plan: DayPlan) async {
        guard plan.capturedCount > 0, plan.vlogPath == nil else { return }
        let output = storageURL.appendingPathComponent("vlog-\(plan.dateKey).mp4")
        guard !FileManager.default.fileExists(atPath: output.path) else { return }
        let captured = plan.moments.filter { $0.status == .captured }
        guard !captured.isEmpty else { return }
        _ = try? await composer.compose(moments: captured, outputURL: output)
    }

    private func shouldAutoCompose(plan: DayPlan) -> Bool {
        plan.capturedCount > 0 && plan.vlogPath == nil && !isComposing
    }

    // MARK: - Schedule

    func scheduleToday() async {
        do {
            let granted = try await scheduler.requestPermission()
            guard granted else {
                permissionMessage = "通知がオフです。Settingsで通知を許可すると、撮影タイミングのお知らせが届きます。"
                return
            }
            // Re-use today's plan if it already exists; otherwise build a fresh one.
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

    // MARK: - Capture

    func openCaptureFromNotification(momentID: String?) {
        if let momentID, let id = UUID(uuidString: momentID) {
            selectedMomentID = id
        }
        showingCapture = true
    }

    func handle(url: URL) {
        if url.host == "capture" {
            selectedMomentID = nil
            showingCapture = true
        }
    }

    func clipURL(for moment: CaptureMoment) -> URL {
        storageURL.appendingPathComponent("\(moment.id.uuidString).mov")
    }

    func tempClipURL(for moment: CaptureMoment) -> URL {
        storageURL.appendingPathComponent("temp-\(moment.id.uuidString).mov")
    }

    func clearForDebug() {
        plan = Self.makePlan(for: Date())
        save()
    }

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
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        plan.moments[index].customText = (trimmed?.isEmpty ?? true) ? nil : trimmed
        save()
    }

    /// Currently active hourly moment whose 5-minute window is open, or nil.
    var activeHourlyMoment: CaptureMoment? {
        let now = Date()
        return plan.moments.first { m in
            m.kind == .hourly && m.status == .scheduled && m.isWithinCaptureWindow(now: now)
        }
    }

    /// The free slot (if not yet captured).
    var availableFreeMoment: CaptureMoment? {
        plan.moments.first { $0.kind == .free && $0.status == .scheduled }
    }

    // MARK: - Vlogs

    var allVlogs: [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storageURL, includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.lastPathComponent.hasPrefix("vlog-") && $0.pathExtension == "mp4" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
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
            let url = try await composer.compose(moments: captured, outputURL: output)
            plan.vlogPath = url.path
            save()
        } catch {
            permissionMessage = "ショート生成に失敗しました: \(error.localizedDescription)"
        }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(plan) else { return }
        try? data.write(to: planURL, options: [.atomic])
    }

    // MARK: - Plan generation

    /// Build the day's plan: 1 hourly slot per hour from 7:00 to 24:00 (max 17),
    /// skipping hours already in the past, plus exactly 1 free slot. Total max 18.
    private static func makePlan(for date: Date) -> DayPlan {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)

        var hourlyMoments: [CaptureMoment] = []
        for hour in 7...23 {  // 17 hourly slots: hour-bands 7-24
            guard let slot = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dayStart) else { continue }
            if slot.addingTimeInterval(5 * 60) < date { continue }
            hourlyMoments.append(CaptureMoment(
                id: UUID(),
                scheduledAt: slot,
                clipPath: nil,
                status: .scheduled,
                kind: .hourly,
                customText: nil,
                retakeCount: 0,
                capturedAt: nil
            ))
        }

        let freeMoment = CaptureMoment(
            id: UUID(),
            scheduledAt: dayStart,
            clipPath: nil,
            status: .scheduled,
            kind: .free,
            customText: nil,
            retakeCount: 0,
            capturedAt: nil
        )

        return DayPlan(
            dateKey: dateKey(for: date),
            moments: hourlyMoments + [freeMoment],
            vlogPath: nil
        )
    }

    private static func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
