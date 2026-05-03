import Foundation

enum MomentStatus: String, Codable {
    case scheduled
    case captured
    case missed
}

enum MomentKind: String, Codable {
    case hourly   // hourly slot 7:00–23:00 (max 17)
    case free     // 1 free anytime slot per day
}

struct CaptureMoment: Identifiable, Codable, Equatable {
    var id: UUID
    var scheduledAt: Date
    var clipPath: String?
    var status: MomentStatus
    var kind: MomentKind = .hourly
    var customText: String?
    var retakeCount: Int = 0
    var capturedAt: Date?

    var clipURL: URL? {
        guard let clipPath else { return nil }
        return URL(fileURLWithPath: clipPath)
    }

    /// Hourly: active within 5 min of scheduled time. Free: always active.
    func isWithinCaptureWindow(now: Date = Date()) -> Bool {
        switch kind {
        case .free:    return true
        case .hourly:  return now >= scheduledAt && now <= scheduledAt.addingTimeInterval(5 * 60)
        }
    }
}

struct DayPlan: Codable, Equatable {
    var dateKey: String
    var moments: [CaptureMoment]
    var vlogPath: String?
    var selectedMusicID: String?   // nil = use default

    var capturedCount: Int { moments.filter { $0.status == .captured }.count }
    var totalSlots: Int { moments.count }
    var vlogURL: URL? { vlogPath.map { URL(fileURLWithPath: $0) } }
}

// MARK: - Music

struct MusicTrack: Identifiable, Equatable {
    let id: String        // bundle resource name (no extension)
    let displayName: String

    var url: URL? { Bundle.main.url(forResource: id, withExtension: "mp3") }

    static let all: [MusicTrack] = [
        MusicTrack(id: "city_drift",   displayName: "City Drift"),
        MusicTrack(id: "golden_hour",  displayName: "Golden Hour"),
        MusicTrack(id: "window_film",  displayName: "Window Film"),
    ]

    static func track(for id: String?) -> MusicTrack? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// Deterministic pick based on date key so it stays consistent per day.
    static func defaultFor(dateKey: String) -> MusicTrack {
        let hash = dateKey.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return all[abs(hash) % all.count]
    }
}
