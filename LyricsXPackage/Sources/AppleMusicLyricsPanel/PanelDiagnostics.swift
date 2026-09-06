import Foundation

extension AppleMusicLyrics {
    /// The master switch for everything the panel logs and signposts.
    ///
    /// Every `@Loggable` / `@Signpostable` type in this module passes
    /// `PanelDiagnostics.isEnabled` as its `isEnabled:` argument, so one flag
    /// decides whether the display-link cadence reports, the emphasis scheduling
    /// logs, the backdrop frame timings and their signposts exist at runtime.
    /// It is off by default and read once, at first use, from either of:
    ///
    /// - the environment variable `LYRICSX_PANEL_DIAGNOSTICS=1` (handy on an
    ///   Xcode scheme), or
    /// - the user-defaults key `AppleMusicLyricsDiagnosticsEnabled`
    ///   (`defaults write dev.JH.LyricsX AppleMusicLyricsDiagnosticsEnabled -bool YES`
    ///   for a running Debug build, `com.JH.LyricsX` for Release).
    ///
    /// The per-frame stage signposts have a second, finer switch of their own,
    /// `LYRICSX_DETAILED_FRAME_SIGNPOSTS`; it only has an effect while this one
    /// is on.
    enum PanelDiagnostics {
        static let environmentKey = "LYRICSX_PANEL_DIAGNOSTICS"
        static let userDefaultsKey = "AppleMusicLyricsDiagnosticsEnabled"

        static let isEnabled: Bool = resolveIsEnabled()

        static func resolveIsEnabled(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            userDefaults: UserDefaults = .standard
        ) -> Bool {
            if environment[environmentKey] == "1" {
                return true
            }
            return userDefaults.bool(forKey: userDefaultsKey)
        }
    }
}
