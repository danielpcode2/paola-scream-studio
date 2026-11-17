import CoreGraphics
import Foundation

/// Builds automatic zoom segments around clicks.
enum ZoomPlanner {
    static func plan(
        clicks: [CursorSample],
        duration: Double,
        scale: Double,
        lead: Double = 0.5,
        hold: Double = 1.8,
        mergeGap: Double = 0.8,
        minLength: Double = 1.6
    ) -> [ZoomSegment] {
        guard duration > 0 else { return [] }
        let times = clicks.map(\.t).filter { $0 >= 0 && $0 <= duration }.sorted()
        var ranges: [(start: Double, end: Double)] = []
        for t in times {
            let start = max(0, t - lead)
            let end = min(duration, t + hold)
            if let last = ranges.last, start <= last.end + mergeGap {
                ranges[ranges.count - 1].end = max(last.end, end)
            } else {
                ranges.append((start, end))
            }
        }
        let segments = ranges.map { range in
            let end = range.end - range.start < minLength ? min(duration, range.start + minLength) : range.end
            return ZoomSegment(start: range.start, end: end, scale: scale)
        }
        return ZoomEditing.normalized(segments, duration: duration)
    }
}

/// Evaluates the zoom level and camera center at a given time.
enum ZoomTimeline {
    static let ramp = 0.5

    static func scale(at t: Double, segments: [ZoomSegment]) -> Double {
        var result = 1.0
        for segment in segments where segment.isEnabled && t >= segment.start && t <= segment.end {
            let fadeIn = smoothstep((t - segment.start) / ramp)
            let fadeOut = smoothstep((segment.end - t) / ramp)
            result = max(result, 1 + (segment.scale - 1) * min(fadeIn, fadeOut))
        }
        return result
    }

    /// Keeps the zoomed viewport inside the frame (normalized coordinates).
    static func clampedCenter(_ center: CGPoint, scale: Double) -> CGPoint {
        let half = 0.5 / max(scale, 1)
        return CGPoint(
            x: min(max(center.x, half), 1 - half),
            y: min(max(center.y, half), 1 - half)
        )
    }

    private static func smoothstep(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x * x * (3 - 2 * x)
    }
}

extension ZoomTimeline {
    struct State: Equatable {
        var scale: Double
        /// Fixed focus of the dominant segment; nil = follow the cursor.
        var focus: CGPoint?
        var style: ZoomStyle = .classic
        /// Full level of the dominant segment (`scale` ramps towards it).
        var segmentScale: Double = 1

        /// 0...1 ramp of the dominant segment.
        var progress: Double { segmentScale > 1.0001 ? (scale - 1) / (segmentScale - 1) : 0 }
    }

    /// Zoom level and focus of the segment contributing the most at `t`.
    static func state(at t: Double, segments: [ZoomSegment]) -> State {
        var best = State(scale: 1, focus: nil)
        for segment in segments where segment.isEnabled {
            let value = scale(at: t, segments: [segment])
            if value > best.scale {
                best = State(scale: value, focus: segment.focus, style: segment.resolvedStyle, segmentScale: segment.scale)
            }
        }
        return best
    }
}

/// Timeline editing rules for spans (zooms, cuts, camera layouts, annotations): inside the
/// recording, minimum length and, unless `allowsOverlap`, no overlaps.
enum SpanEditing {
    static let minLength = 0.5

    enum Edge { case start, end }

    /// Sorted, clamped and non-overlapping (a span that overlaps the previous one starts at its end).
    static func normalized<T: TimelineSpan>(_ spans: [T], duration: Double) -> [T] {
        var result: [T] = []
        for var span in spans.sorted(by: { $0.start < $1.start }) {
            span.start = max(span.start, result.last?.end ?? 0, 0)
            if duration > 0 { span.end = min(span.end, duration) }
            guard span.end - span.start >= minLength else { continue }
            result.append(span)
        }
        return result
    }

    /// Moves a span keeping its length, between its neighbours and the timeline bounds.
    static func move<T: TimelineSpan>(_ spans: [T], id: UUID, to start: Double, duration: Double, allowsOverlap: Bool = false) -> [T] {
        let sorted = spans.sorted { $0.start < $1.start }
        guard let index = sorted.firstIndex(where: { $0.id == id }) else { return spans }
        var result = sorted
        let length = sorted[index].end - sorted[index].start
        let lower = !allowsOverlap && index > 0 ? sorted[index - 1].end : 0
        let upper = (!allowsOverlap && index + 1 < sorted.count ? sorted[index + 1].start : duration) - length
        guard upper >= lower else { return spans }
        let newStart = min(max(start, lower), upper)
        result[index].start = newStart
        result[index].end = newStart + length
        return result
    }

    /// Moves one edge of a span, keeping the minimum length and not crossing neighbours.
    static func resize<T: TimelineSpan>(_ spans: [T], id: UUID, edge: Edge, to time: Double, duration: Double, allowsOverlap: Bool = false) -> [T] {
        let sorted = spans.sorted { $0.start < $1.start }
        guard let index = sorted.firstIndex(where: { $0.id == id }) else { return spans }
        var result = sorted
        switch edge {
        case .start:
            let lower = !allowsOverlap && index > 0 ? sorted[index - 1].end : 0
            result[index].start = min(max(time, lower), sorted[index].end - minLength)
        case .end:
            let upper = !allowsOverlap && index + 1 < sorted.count ? sorted[index + 1].start : duration
            result[index].end = max(min(time, upper), sorted[index].start + minLength)
        }
        return result
    }

    /// Where a new span of `length` would go when added at `time`, or nil when `time` is inside an
    /// existing span (without overlaps) or the free gap is too short.
    static func freeSlot<T: TimelineSpan>(
        _ spans: [T], at time: Double, length: Double, duration: Double, allowsOverlap: Bool = false
    ) -> (start: Double, end: Double)? {
        var start = max(0, min(time, duration - minLength))
        var end = min(start + length, duration)
        if !allowsOverlap {
            if spans.contains(where: { time >= $0.start && time <= $0.end }) { return nil }
            let previousEnd = spans.filter { $0.end <= time }.map(\.end).max() ?? 0
            let nextStart = spans.filter { $0.start >= time }.map(\.start).min() ?? duration
            start = max(time, previousEnd)
            end = min(start + length, nextStart)
            if end - start < length { start = max(previousEnd, end - length) }
        }
        return end - start >= minLength ? (start, end) : nil
    }

    /// Adds a span at `time` in the free gap there (or anywhere when overlaps are allowed).
    /// Returns the span to select: the existing one if `time` falls inside one, nil if no room.
    static func insert<T: TimelineSpan>(
        _ spans: [T], at time: Double, length: Double = 2.5, duration: Double, allowsOverlap: Bool = false,
        make: (Double, Double) -> T
    ) -> (spans: [T], selected: UUID?) {
        let sorted = spans.sorted { $0.start < $1.start }
        if !allowsOverlap, let hit = sorted.first(where: { time >= $0.start && time <= $0.end }) {
            return (sorted, hit.id)
        }
        guard let slot = freeSlot(sorted, at: time, length: length, duration: duration, allowsOverlap: allowsOverlap) else {
            return (sorted, nil)
        }
        let span = make(slot.start, slot.end)
        return ((sorted + [span]).sorted { $0.start < $1.start }, span.id)
    }

    /// Splits a span at `time` into two (the second gets a new id). Nil when too close to an edge.
    static func split<T: TimelineSpan>(_ spans: [T], id: UUID, at time: Double) -> (spans: [T], second: UUID)? {
        guard let index = spans.firstIndex(where: { $0.id == id }),
              time - spans[index].start >= minLength, spans[index].end - time >= minLength
        else { return nil }
        var result = spans
        var second = spans[index]
        second.id = UUID()
        second.start = time
        result[index].end = time
        result.append(second)
        return (result.sorted { $0.start < $1.start }, second.id)
    }

    /// Places a copy of `span` at `time` (or the nearest free gap). Nil when there is no room.
    static func place<T: TimelineSpan>(_ span: T, in spans: [T], at time: Double, duration: Double, allowsOverlap: Bool = false) -> (spans: [T], id: UUID)? {
        let length = span.end - span.start
        guard let slot = freeSlot(spans, at: time, length: length, duration: duration, allowsOverlap: allowsOverlap),
              slot.end - slot.start >= length - 0.001
        else { return nil }
        var copy = span
        copy.id = UUID()
        copy.start = slot.start
        copy.end = slot.end
        return ((spans + [copy]).sorted { $0.start < $1.start }, copy.id)
    }
}

/// Zoom-specific convenience kept for readability at call sites.
enum ZoomEditing {
    static let minLength = SpanEditing.minLength
    typealias Edge = SpanEditing.Edge

    static func normalized(_ segments: [ZoomSegment], duration: Double) -> [ZoomSegment] {
        SpanEditing.normalized(segments, duration: duration)
    }

    static func move(_ segments: [ZoomSegment], id: UUID, to start: Double, duration: Double) -> [ZoomSegment] {
        SpanEditing.move(segments, id: id, to: start, duration: duration)
    }

    static func resize(_ segments: [ZoomSegment], id: UUID, edge: Edge, to time: Double, duration: Double) -> [ZoomSegment] {
        SpanEditing.resize(segments, id: id, edge: edge, to: time, duration: duration)
    }

    static func insert(
        _ segments: [ZoomSegment], at time: Double, length: Double = 2.5, scale: Double, duration: Double
    ) -> (segments: [ZoomSegment], selected: UUID?) {
        let result = SpanEditing.insert(segments, at: time, length: length, duration: duration) { start, end in
            ZoomSegment(start: start, end: end, scale: scale)
        }
        return (result.spans, result.selected)
    }
}

/// Ease-in/out progress of a span at `t` (0 outside, 1 in the middle).
enum SpanRamp {
    static func progress(at t: Double, start: Double, end: Double, ramp: Double) -> Double {
        guard t >= start, t <= end else { return 0 }
        let fadeIn = smooth((t - start) / ramp)
        let fadeOut = smooth((end - t) / ramp)
        return min(fadeIn, fadeOut)
    }

    static func smooth(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x * x * (3 - 2 * x)
    }
}
