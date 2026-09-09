import Foundation
import LyricsKit

extension Lyrics {
    public var originalTimingSource: String? {
        get { metadata.data[.init("originalTimingSource")] as? String }
        set { metadata.data[.init("originalTimingSource")] = newValue }
    }
}

/// Keeps the original positions so repeated adjustments do not accumulate
/// rounding errors or lose timing when a line is clamped at zero.
public struct LyricsTimestampAdjustment {
    private let originalPositions: [TimeInterval]
    public private(set) var offset: Int

    public init(lyrics: Lyrics) {
        originalPositions = lyrics.lines.map(\.position)
        offset = lyrics.offset
    }

    /// Positive offsets advance lyrics, matching LRC offset semantics.
    /// Apply only to the same lyrics instance used to create this adjustment.
    public mutating func apply(offset: Int, to lyrics: Lyrics) {
        let seconds = TimeInterval(offset) / 1000
        for index in lyrics.lines.indices {
            lyrics.lines[index].position = max(0, originalPositions[index] - seconds)
        }
        // Karaoke attachment times are relative to the line and stay unchanged.
        lyrics.idTags.removeValue(forKey: .offset)
        self.offset = offset
    }
}
