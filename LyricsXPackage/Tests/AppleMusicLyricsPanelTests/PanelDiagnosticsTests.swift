import Foundation
import Testing
@testable import AppleMusicLyricsPanel

/// The panel's logging and signposting hang off one switch. These pin the
/// contract that matters for a shipping build: nothing is on unless somebody
/// asked, and either the environment or the defaults key is enough to ask.
struct PanelDiagnosticsTests {
    private static func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "dev.JH.LyricsX.PanelDiagnosticsTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }

    @Test func diagnosticsAreOffUnlessAsked() throws {
        let userDefaults = try Self.makeIsolatedDefaults()
        #expect(!AppleMusicLyrics.PanelDiagnostics.resolveIsEnabled(environment: [:], userDefaults: userDefaults))
        #expect(!AppleMusicLyrics.PanelDiagnostics.resolveIsEnabled(
            environment: [AppleMusicLyrics.PanelDiagnostics.environmentKey: "0"],
            userDefaults: userDefaults
        ))
    }

    @Test func theEnvironmentVariableTurnsDiagnosticsOn() throws {
        let userDefaults = try Self.makeIsolatedDefaults()
        #expect(AppleMusicLyrics.PanelDiagnostics.resolveIsEnabled(
            environment: [AppleMusicLyrics.PanelDiagnostics.environmentKey: "1"],
            userDefaults: userDefaults
        ))
    }

    @Test func theDefaultsKeyTurnsDiagnosticsOn() throws {
        let userDefaults = try Self.makeIsolatedDefaults()
        userDefaults.set(true, forKey: AppleMusicLyrics.PanelDiagnostics.userDefaultsKey)
        #expect(AppleMusicLyrics.PanelDiagnostics.resolveIsEnabled(environment: [:], userDefaults: userDefaults))
        userDefaults.set(false, forKey: AppleMusicLyrics.PanelDiagnostics.userDefaultsKey)
        #expect(!AppleMusicLyrics.PanelDiagnostics.resolveIsEnabled(environment: [:], userDefaults: userDefaults))
    }
}
