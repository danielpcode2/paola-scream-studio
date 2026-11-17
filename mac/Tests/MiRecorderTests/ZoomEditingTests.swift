import CoreImage
import XCTest
@testable import MiRecorder

final class ZoomEditingTests: XCTestCase {
    private let a = ZoomSegment(start: 1, end: 3, scale: 2)
    private let b = ZoomSegment(start: 5, end: 8, scale: 2)

    func testOverlappingZoomsAreFixed() {
        let overlapping = [ZoomSegment(start: 0.5, end: 3.3, scale: 2), ZoomSegment(start: 2.3, end: 4.8, scale: 2)]
        let fixed = ZoomEditing.normalized(overlapping, duration: 10)
        XCTAssertEqual(fixed.map(\.start), [0.5, 3.3])
        XCTAssertEqual(fixed.map(\.end), [3.3, 4.8])
    }

    func testMoveStopsAtNeighboursAndBounds() {
        var moved = ZoomEditing.move([a, b], id: a.id, to: 4.5, duration: 10)
        XCTAssertEqual(moved[0].start, 3, "stops where the next zoom starts")
        XCTAssertEqual(moved[0].end, 5)
        moved = ZoomEditing.move([a, b], id: b.id, to: 20, duration: 10)
        XCTAssertEqual(moved[1].end, 10, "stays inside the recording")
        moved = ZoomEditing.move([a, b], id: a.id, to: -3, duration: 10)
        XCTAssertEqual(moved[0].start, 0)
    }

    func testResizeKeepsMinimumLengthAndNoOverlap() {
        var resized = ZoomEditing.resize([a, b], id: a.id, edge: .end, to: 7, duration: 10)
        XCTAssertEqual(resized[0].end, 5)
        resized = ZoomEditing.resize([a, b], id: a.id, edge: .start, to: 2.9, duration: 10)
        XCTAssertEqual(resized[0].start, 3 - ZoomEditing.minLength, accuracy: 1e-9)
        resized = ZoomEditing.resize([a, b], id: b.id, edge: .start, to: 2, duration: 10)
        XCTAssertEqual(resized[1].start, 3, "cannot cross the previous zoom")
    }

    func testInsertFitsGapOrSelectsExisting() {
        let inside = ZoomEditing.insert([a, b], at: 2, scale: 2, duration: 10)
        XCTAssertEqual(inside.selected, a.id)
        XCTAssertEqual(inside.segments.count, 2)

        let gap = ZoomEditing.insert([a, b], at: 3.5, scale: 2, duration: 10)
        XCTAssertEqual(gap.segments.count, 3)
        let added = try? XCTUnwrap(gap.segments.first { $0.id == gap.selected })
        XCTAssertEqual(added?.start, 3)
        XCTAssertEqual(added?.end, 5, "fills the 2 s gap without overlapping")

        let tight = ZoomEditing.insert([a, ZoomSegment(start: 3.2, end: 6, scale: 2)], at: 3.1, scale: 2, duration: 10)
        XCTAssertNil(tight.selected, "gap shorter than the minimum")
    }

    func testFixedFocusWinsOverCursor() {
        var segment = a
        segment.focus = CGPoint(x: 0.2, y: 0.8)
        let state = ZoomTimeline.state(at: 2, segments: [segment, b])
        XCTAssertEqual(state.focus, CGPoint(x: 0.2, y: 0.8))
        XCTAssertEqual(state.scale, 2, accuracy: 1e-9)
        XCTAssertNil(ZoomTimeline.state(at: 6.5, segments: [segment, b]).focus)
    }
}

final class SpanActionsTests: XCTestCase {
    private let a = ZoomSegment(start: 1, end: 4, scale: 2)
    private let b = ZoomSegment(start: 6, end: 8, scale: 2)

    func testSplitCreatesTwoAdjacentItems() throws {
        let result = try XCTUnwrap(SpanEditing.split([a, b], id: a.id, at: 2.5))
        XCTAssertEqual(result.spans.count, 3)
        XCTAssertEqual(result.spans[0].end, 2.5)
        let second = try XCTUnwrap(result.spans.first { $0.id == result.second })
        XCTAssertEqual(second.start, 2.5)
        XCTAssertEqual(second.end, 4)
        XCTAssertNil(SpanEditing.split([a], id: a.id, at: 1.2), "too close to the edge")
    }

    func testPlaceCopyNeedsAGapAsLongAsTheItem() throws {
        let placed = try XCTUnwrap(SpanEditing.place(b, in: [a, b], at: 9, duration: 12))
        XCTAssertEqual(placed.spans.count, 3)
        XCTAssertNotEqual(placed.id, b.id)
        XCTAssertNil(SpanEditing.place(a, in: [a, b], at: 4.2, duration: 12), "3 s item does not fit the 2 s gap")
    }

    func testFreeSlotForHoverPreview() {
        XCTAssertNil(SpanEditing.freeSlot([a, b], at: 2, length: 2.5, duration: 12), "inside an item")
        let slot = SpanEditing.freeSlot([a, b], at: 4.5, length: 2.5, duration: 12)
        XCTAssertEqual(slot?.start, 4)
        XCTAssertEqual(slot?.end, 6)
    }

    func testOlderZoomsDecodeAsClassic() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","start":1,"end":2,"scale":2,"isEnabled":true}"#
        let zoom = try JSONDecoder().decode(ZoomSegment.self, from: Data(json.utf8))
        XCTAssertEqual(zoom.resolvedStyle, .classic)
    }

    func testLoupeKeepsFrameUnzoomedOutsideTheCircle() throws {
        var settings = EditSettings()
        var loupe = ZoomSegment(start: 0, end: 4, scale: 3)
        loupe.style = .loupe
        loupe.focus = CGPoint(x: 0.5, y: 0.5)
        settings.zoomSegments = [loupe]
        settings.padding = 0
        settings.shadow = 0
        settings.showCursor = false
        let size = CGSize(width: 400, height: 200)
        let renderer = FrameCompositor(sourceSize: size, cursor: CursorTrack(), settings: settings, sprite: nil)
        let source = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8)).cropped(to: CGRect(origin: .zero, size: size))
        let image = renderer.render(source: source, at: 2)
        XCTAssertEqual(image.extent.size, size)
        let state = ZoomTimeline.state(at: 2, segments: settings.zoomSegments)
        XCTAssertEqual(state.style, .loupe)
        XCTAssertEqual(state.progress, 1, accuracy: 1e-9)
    }
}
