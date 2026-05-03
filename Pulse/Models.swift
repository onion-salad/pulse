import Foundation

enum MomentStatus: String, Codable {
    case scheduled
    case captured
    case missed
}

enum MomentKind: String, Codable {
    case hourly   // hourly slot 7:00 - 24:00 (max 17)
    case free     // 1 free anytime slot per day
}

struct CaptureMoment: Identifiable, Codable, Equatable {
    var id: UUID
    var scheduledAt: Date          // for free slot, this is just a placeholder (e.g. start of day)
    var clipPath: String?
    var status: MomentStatus
    var kind: MomentKind = .hourly
    var customText: String?        // text shown in center of this clip in the final vlog
    var retakeCount: Int = 0       // how many times the user retook this clip (0..2)
    var capturedAt: Date?          // actual capture time, for the timestamp overlay

    var clipURL: URL? {
        guard let clipPath else { return nil }
        return URL(fileURLWithPath: clipPath)
    }

    /// Window during which a notification-driven hourly moment is "active"
    /// (notification fired up to 5 minutes ago). Free slot is always available.
    func isWithinCaptureWindow(now: Date = Date()) -> Bool {
        switch kind {
        case .free:
            return true
        case .hourly:
            let windowEnd = scheduledAt.addingTimeInterval(5 * 60)
            return now >= scheduledAt && now <= windowEnd
        }
    }
}

struct DayPlan: Codable, Equatable {
    var dateKey: String
    var moments: [CaptureMoment]
    var vlogPath: String?

    var capturedCount: Int {
        moments.filter { $0.status == .captured }.count
    }

    var totalSlots: Int { moments.count }

    var vlogURL: URL? {
        guard let vlogPath else { return nil }
        return URL(fileURLWithPath: vlogPath)
    }
}
