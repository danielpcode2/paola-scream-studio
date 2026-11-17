import CoreGraphics

/// Resampled cursor path with optional spring smoothing (critically damped).
struct CursorPath: Sendable {
    private let start: Double
    private let step: Double
    private let points: [CGPoint]

    init?(samples: [CursorSample], smoothing: Double, step: Double = 1.0 / 120.0) {
        let sorted = samples.sorted { $0.t < $1.t }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        self.start = first.t
        self.step = step

        let count = max(1, Int(((last.t - first.t) / step).rounded(.up)) + 1)
        var raw: [CGPoint] = []
        raw.reserveCapacity(count)
        var index = 0
        for i in 0..<count {
            let t = first.t + Double(i) * step
            while index + 1 < sorted.count, sorted[index + 1].t <= t { index += 1 }
            let a = sorted[index]
            if index + 1 < sorted.count {
                let b = sorted[index + 1]
                let span = b.t - a.t
                let f = span > 0 ? (t - a.t) / span : 0
                raw.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            } else {
                raw.append(CGPoint(x: a.x, y: a.y))
            }
        }

        let smoothing = min(max(smoothing, 0), 1)
        guard smoothing > 0.001 else {
            points = raw
            return
        }
        // Higher smoothing => lower spring frequency. Semi-implicit Euler is stable for omega*dt < 2.
        let omega = 4 + 40 * pow(1 - smoothing, 1.5)
        var p = raw[0]
        var v = CGPoint.zero
        var out: [CGPoint] = []
        out.reserveCapacity(raw.count)
        for target in raw {
            let ax = omega * omega * (target.x - p.x) - 2 * omega * v.x
            let ay = omega * omega * (target.y - p.y) - 2 * omega * v.y
            v.x += ax * step
            v.y += ay * step
            p.x += v.x * step
            p.y += v.y * step
            out.append(p)
        }
        points = out
    }

    func position(at t: Double) -> CGPoint {
        let position = (t - start) / step
        if position <= 0 { return points[0] }
        let lower = Int(position)
        if lower >= points.count - 1 { return points[points.count - 1] }
        let f = position - Double(lower)
        let a = points[lower], b = points[lower + 1]
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }
}
