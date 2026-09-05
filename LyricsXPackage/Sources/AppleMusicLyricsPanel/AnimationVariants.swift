import Foundation

extension AppleMusicLyrics {
    /// Which line-change motion the panel runs when playback advances to a new
    /// line. Both variants share `LineTransitionCoordinator`; only the rows that
    /// take part, their curves and their delays differ.
    ///
    /// Selected through a hidden user-defaults key so the two can be compared
    /// side by side without a rebuild. The key is read on every line change, so
    /// `defaults write` takes effect on the next advance.
    enum LineCascadeVariant: String, CaseIterable, Sendable {
        /// Apple Music 26.6's cascade: word-timed lyrics choose a spring from the
        /// sung gap, otherwise using the fixed fallback. The leading two rows
        /// start together; a new selection waits until the cascade has settled.
        case appleMusic26
        /// The cascade restored from the panel's earlier SwiftUI renderer: three
        /// rows above the selection ease into place, the selection and five rows
        /// below spring with an 80 ms stagger, and a rapid second change collapses
        /// into a critically damped clip settle.
        case legacySwiftUI

        static let userDefaultsKey = "AppleMusicLyricsCascadeVariant"
        static let `default`: LineCascadeVariant = .appleMusic26

        static func resolve(from userDefaults: UserDefaults = .standard) -> LineCascadeVariant {
            guard let rawValue = userDefaults.string(forKey: userDefaultsKey),
                  let variant = LineCascadeVariant(rawValue: rawValue) else {
                return .default
            }
            return variant
        }
    }

    /// How much emphasis a word carrying structured (`SynchronizedTextTiming`)
    /// timing receives. Words that only carry inline start tags are unaffected:
    /// they keep the established full-strength phrase fallback either way.
    enum StructuredEmphasisPolicy: String, CaseIterable, Sendable {
        /// Apple Music 26.6's gate: `ar`, `he`, `zh` and `ja` lyrics only lift;
        /// other languages swell and glow only for words longer than one second
        /// and at most seven characters, and the first glyph waits one stagger.
        case appleMusic26
        /// Every structured word gets the full swell and glow with no leading
        /// delay, the look the inline-tag fallback already has.
        case fullEmphasis

        static let userDefaultsKey = "AppleMusicLyricsStructuredEmphasisPolicy"
        static let `default`: StructuredEmphasisPolicy = .appleMusic26

        static func resolve(from userDefaults: UserDefaults = .standard) -> StructuredEmphasisPolicy {
            guard let rawValue = userDefaults.string(forKey: userDefaultsKey),
                  let policy = StructuredEmphasisPolicy(rawValue: rawValue) else {
                return .default
            }
            return policy
        }
    }
}
