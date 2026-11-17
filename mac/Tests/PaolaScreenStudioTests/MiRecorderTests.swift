import AVFoundation
import XCTest
@testable import PaolaScreenStudio

final class ZoomTests: XCTestCase {
    func testPlannerMergesNearbyClicksAndSeparatesDistantOnes() {
        let clicks = [1.0, 1.5, 10.0].map { CursorSample(t: $0, x: 0.5, y: 0.5) }
        let segments = ZoomPlanner.plan(clicks: clicks, duration: 20, scale: 2)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, 0.5, accuracy: 1e-9)
        XCTAssertEqual(segments[0].end, 3.3, accuracy: 1e-9)
        XCTAssertEqual(segments[1].start, 9.5, accuracy: 1e-9)
        XCTAssertEqual(segments[1].scale, 2)
    }

    func testPlannerClampsToDuration() {
        let segments = ZoomPlanner.plan(clicks: [CursorSample(t: 4.9, x: 0, y: 0)], duration: 5, scale: 2)
        XCTAssertEqual(segments.count, 1)
        XCTAssertLessThanOrEqual(segments[0].end, 5)
    }

    func testTimelineRampsInAndOut() {
        let segment = ZoomSegment(start: 1, end: 4, scale: 2)
        XCTAssertEqual(ZoomTimeline.scale(at: 0.5, segments: [segment]), 1)
        XCTAssertEqual(ZoomTimeline.scale(at: 2.5, segments: [segment]), 2, accuracy: 1e-9)
        let rampingIn = ZoomTimeline.scale(at: 1.25, segments: [segment])
        XCTAssertGreaterThan(rampingIn, 1)
        XCTAssertLessThan(rampingIn, 2)
        var disabled = segment
        disabled.isEnabled = false
        XCTAssertEqual(ZoomTimeline.scale(at: 2.5, segments: [disabled]), 1)
    }

    func testCenterStaysInsideFrame() {
        let c = ZoomTimeline.clampedCenter(CGPoint(x: 0, y: 1), scale: 2)
        XCTAssertEqual(c.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.75, accuracy: 1e-9)
    }
}

final class CursorPathTests: XCTestCase {
    private let samples = [
        CursorSample(t: 0, x: 0, y: 0),
        CursorSample(t: 1, x: 1, y: 1),
        CursorSample(t: 3, x: 1, y: 1),
    ]

    func testRawPathInterpolatesLinearly() throws {
        let path = try XCTUnwrap(CursorPath(samples: samples, smoothing: 0))
        XCTAssertEqual(path.position(at: 0.5).x, 0.5, accuracy: 0.01)
        XCTAssertEqual(path.position(at: 10).x, 1, accuracy: 1e-9)
        XCTAssertEqual(path.position(at: -1).x, 0, accuracy: 1e-9)
    }

    func testSmoothedPathLagsThenSettles() throws {
        let path = try XCTUnwrap(CursorPath(samples: samples, smoothing: 0.7))
        XCTAssertLessThan(path.position(at: 0.5).x, 0.5)
        XCTAssertEqual(path.position(at: 3).x, 1, accuracy: 0.02)
    }

    func testEmptySamplesHaveNoPath() {
        XCTAssertNil(CursorPath(samples: [], smoothing: 0.5))
    }
}

