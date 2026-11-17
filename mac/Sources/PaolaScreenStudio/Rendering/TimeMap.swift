import Foundation

/// Maps between the original recording ("source" seconds, where every edit is stored) and the
/// final video ("edited" seconds) after cuts, speed changes, intro and outro.
struct TimeMap: Sendable, Equatable {
    struct Piece: Sendable, Equatable {
        var sourceStart: Double
        var sourceEnd: Double
        var editedStart: Double
        var rate: Double

        var editedDuration: Double { (sourceEnd - sourceStart) / rate }
    }

    let pieces: [Piece]
    let intro: Double
    let outro: Double
    let sourceDuration: Double

    var contentDuration: Double { pieces.reduce(0) { $0 + $1.editedDuration } }
    var totalDuration: Double { intro + contentDuration + outro }

    static func identity(duration: Double) -> TimeMap {
        TimeMap(edits: [], sourceDuration: duration)
    }

    /// `edits` must be sorted and non-overlapping (see `SpanEditing.normalized`).
    init(edits: [TimeEdit], sourceDuration: Double, intro: Double = 0, outro: Double = 0) {
        self.sourceDuration = sourceDuration
        self.intro = intro
        self.outro = outro
        var pieces: [Piece] = []
        var source = 0.0
        var edited = intro
        func add(_ start: Double, _ end: Double, rate: Double) {
            guard end - start > 0.0001 else { return }
            pieces.append(Piece(sourceStart: start, sourceEnd: end, editedStart: edited, rate: rate))
            edited += (end - start) / rate
        }
        for edit in edits.sorted(by: { $0.start < $1.start }) {
            let start = min(max(edit.start, source), sourceDuration)
            let end = min(max(edit.end, start), sourceDuration)
            add(source, start, rate: 1)
            if !edit.isCut { add(start, end, rate: edit.speed) }
            source = end
        }
        add(source, sourceDuration, rate: 1)
        self.pieces = pieces
    }

    func isIntro(_ edited: Double) -> Bool { intro > 0 && edited < intro }
    func isOutro(_ edited: Double) -> Bool { outro > 0 && edited >= intro + contentDuration }

    /// Recording time shown at an edited time (intro maps to 0, outro to the end).
    func source(atEdited edited: Double) -> Double {
        guard let first = pieces.first, let last = pieces.last else { return 0 }
        if edited <= first.editedStart { return first.sourceStart }
        for piece in pieces where edited < piece.editedStart + piece.editedDuration {
            return piece.sourceStart + (edited - piece.editedStart) * piece.rate
        }
        return last.sourceEnd
    }

    /// Edited time of a recording time; times inside a cut map to where the cut ends.
    func edited(atSource source: Double) -> Double {
        for piece in pieces {
            if source < piece.sourceStart { return piece.editedStart }
            if source <= piece.sourceEnd { return piece.editedStart + (source - piece.sourceStart) / piece.rate }
        }
        return intro + contentDuration
    }

    /// Export/playback range for a trim given in recording time. Untrimmed ends include intro/outro.
    func editedRange(trimStart: Double, trimEnd: Double) -> (start: Double, end: Double) {
        let start = trimStart <= 0.001 ? 0 : edited(atSource: trimStart)
        let end = trimEnd >= sourceDuration - 0.001 ? totalDuration : edited(atSource: trimEnd)
        return (start, max(end, start))
    }
}
