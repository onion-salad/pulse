import Foundation

enum MomentStatus: String, Codable {
    case scheduled
    case captured
    case missed
}

struct CaptureMoment: Identifiable, Codable, Equatable {
    var id: UUID
    var scheduledAt: Date
    var clipPath: String?
    var status: MomentStatus

    var clipURL: URL? {
        guard let clipPath else { return nil }
        return URL(fileURLWithPath: clipPath)
    }
}

struct DayPlan: Codable, Equatable {
    var dateKey: String
    var moments: [CaptureMoment]
    var vlogPath: String?

    var capturedCount: Int {
        moments.filter { $0.status == .captured }.count
    }

    var vlogURL: URL? {
        guard let vlogPath else { return nil }
        return URL(fileURLWithPath: vlogPath)
    }
}

