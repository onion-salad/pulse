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

    func load() {
        try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: planURL),
           let saved = try? JSONDecoder().decode(DayPlan.self, from: data) {
            let todayKey = Self.dateKey(for: Date())

            if saved.dateKey == todayKey {
                plan = saved
                // Auto-compose if 11 clips are ready but no vlog yet (e.g. after a crash)
                if plan.capturedCount == 11 && plan.vlogPath == nil && !isComposing {
                    Task { await composeVlog() }
                }
            } else {
                // New day: silently compose yesterday's clips in the background if needed
                if saved.capturedCount > 0 && saved.vlogPath == nil {
                    let prevPlan = saved
                    let prevOutput = storageURL.appendingPathComponent("vlog-\(prevPlan.dateKey).mp4")
                    Task {
                        let clips = prevPlan.moments.compactMap(\.clipURL)
                        if !clips.isEmpty, !FileManager.default.fileExists(atPath: prevOutput.path) {
                            _ = try? await composer.compose(clips: clips, outputURL: prevOutput)
                        }
                    }
                }
                plan = Self.makePlan(for: Date())
                save()
            }
        } else {
            plan = Self.makePlan(for: Date())
            save()
        }
    }

    func scheduleToday() async {
        do {
            let granted = try await scheduler.requestPermission()
            guard granted else {
                permissionMessage = "通知がオフです。Settingsで通知を許可すると、1日11回の撮影タイミングが届きます。"
                return
            }
            plan = Self.makePlan(for: Date())
            save()
            try await scheduler.schedule(moments: plan.moments)
            permissionMessage = nil
        } catch {
            permissionMessage = error.localizedDescription
        }
    }

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

    func loadTestMoments(_ moments: [CaptureMoment]) {
        plan.moments = moments
        save()
    }

    func clearForDebug() {
        plan = Self.makePlan(for: Date())
        save()
    }

    func registerCapture(momentID: UUID, url: URL) {
        guard let index = plan.moments.firstIndex(where: { $0.id == momentID }) else { return }
        plan.moments[index].clipPath = url.path
        plan.moments[index].status = .captured
        save()

        // Auto-compose when all 11 clips are captured
        if plan.capturedCount == 11 && plan.vlogPath == nil && !isComposing {
            Task { await composeVlog() }
        }
    }

    var allVlogs: [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storageURL, includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.lastPathComponent.hasPrefix("vlog-") && $0.pathExtension == "mp4" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func composeVlog() async {
        let clips = plan.moments.compactMap(\.clipURL)
        guard !clips.isEmpty else { return }

        isComposing = true
        defer { isComposing = false }

        do {
            let output = storageURL.appendingPathComponent("vlog-\(plan.dateKey).mp4")
            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            let url = try await composer.compose(clips: clips, outputURL: output)
            plan.vlogPath = url.path
            save()
        } catch {
            permissionMessage = "ショート生成に失敗しました: \(error.localizedDescription)"
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(plan) else { return }
        try? data.write(to: planURL, options: [.atomic])
    }

    private static func makePlan(for date: Date) -> DayPlan {
        var calendar = Calendar.current
        calendar.locale = Locale.current

        var planDate = date
        let eveningEnd = calendar.date(bySettingHour: 22, minute: 30, second: 0, of: planDate) ?? planDate
        let minimumRemainingWindow: TimeInterval = 2 * 60 * 60

        if date > eveningEnd.addingTimeInterval(-minimumRemainingWindow),
           let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) {
            planDate = tomorrow
        }

        let dayStart = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: planDate) ?? planDate
        let dayEnd = calendar.date(bySettingHour: 22, minute: 30, second: 0, of: planDate) ?? planDate
        let start = max(dayStart, planDate == date ? date.addingTimeInterval(60) : dayStart)
        let span = max(Int(dayEnd.timeIntervalSince(start)), 1)
        let offsets = Set((0..<40).map { _ in Int.random(in: 0..<span) })
            .sorted()
            .prefix(11)

        let moments = offsets.map { offset in
            CaptureMoment(
                id: UUID(),
                scheduledAt: start.addingTimeInterval(TimeInterval(offset)),
                clipPath: nil,
                status: .scheduled
            )
        }

        return DayPlan(
            dateKey: dateKey(for: planDate),
            moments: moments.sorted { $0.scheduledAt < $1.scheduledAt },
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
