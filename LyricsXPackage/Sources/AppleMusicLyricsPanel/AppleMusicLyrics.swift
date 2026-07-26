import Foundation
import Combine
import LyricsXFoundation
import MusicPlayer

/// Namespace for the Apple Music-style lyrics panel. The hosting app extends
/// it with its own glue (window controller, preference wiring).
public enum AppleMusicLyrics {}

extension AppleMusicLyrics {
    /// Everything the panel needs from the hosting app but must not know the
    /// source of — user preferences and app-level lyric policy. The defaults
    /// are self-contained so probe builds (`swift test`) run without any app.
    public struct HostEnvironment {
        /// The player the panel reads playback state from and sends transport
        /// commands to. The app passes its `MusicPlayers.Selected.shared`; the
        /// default is an inert `Virtual` player so probes need no real player.
        public var player: MusicPlayerProtocol

        /// Whether a line's translation row is shown at all.
        public var isBilingualPreferred: () -> Bool

        /// Applied to a translation before display. The app routes this
        /// through its Chinese-conversion preference.
        public var transformTranslation: (String) -> String

        /// The delay added to raw playback time before it is compared against
        /// lyric timestamps. The app folds its global user-set offset in here;
        /// the default is just the lyrics file's own `[offset:]` tag.
        public var lyricsTimeDelay: (Lyrics) -> TimeInterval

        /// Fires when the two translation policies above may return new
        /// values, so already-built lines re-render. The app wires this to its
        /// bilingual / Chinese-conversion preference changes.
        public var translationSettingsDidChange: AnyPublisher<Void, Never>

        public init(
            player: MusicPlayerProtocol = MusicPlayers.Virtual(),
            isBilingualPreferred: @escaping () -> Bool = { true },
            transformTranslation: @escaping (String) -> String = { $0 },
            lyricsTimeDelay: @escaping (Lyrics) -> TimeInterval = { TimeInterval($0.offset) / 1000 },
            translationSettingsDidChange: AnyPublisher<Void, Never> = Empty(completeImmediately: false).eraseToAnyPublisher()
        ) {
            self.player = player
            self.isBilingualPreferred = isBilingualPreferred
            self.transformTranslation = transformTranslation
            self.lyricsTimeDelay = lyricsTimeDelay
            self.translationSettingsDidChange = translationSettingsDidChange
        }
    }

    /// Set by the app before the panel is first shown; left at its defaults in
    /// probe harnesses.
    public static var hostEnvironment = HostEnvironment()
}

/// The app declares a `selectedPlayer` alias in `Global.swift`; this twin
/// keeps the moved sources reading the same way while resolving through the
/// host environment (the app's shared selected player once installed).
var selectedPlayer: MusicPlayerProtocol {
    AppleMusicLyrics.hostEnvironment.player
}

extension Lyrics {
    /// The app has its own `adjustedTimeDelay` (user-defaults-backed); this
    /// module-internal twin keeps the moved sources reading the same way while
    /// routing the value through the host environment.
    var adjustedTimeDelay: TimeInterval {
        AppleMusicLyrics.hostEnvironment.lyricsTimeDelay(self)
    }
}
