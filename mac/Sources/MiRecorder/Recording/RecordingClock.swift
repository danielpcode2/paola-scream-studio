import Foundation

/// Maps system uptime to project time when a recording is made of several segments
/// (one per pause/resume). Time spent paused does not exist on the project timeline.
struct RecordingClock: Sendable {
    struct Segment: Sendable {
        var startUptime: TimeInterval
        var duration: Double
    }

    let segments: [Segment]

    var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }

    /// Project time for an uptime, or nil while paused / after the end.
    /// Moments before the first segment map to 0.
    func projectTime(_ uptime: TimeInterval) -> Double? {
        var offset = 0.0
        for (index, segment) in segments.enumerated() {
            if uptime < segment.startUptime { return index == 0 ? 0 : nil }
            if uptime <= segment.startUptime + segment.duration {
                return offset + uptime - segment.startUptime
            }
            offset += segment.duration
        }
        return nil
    }
}
