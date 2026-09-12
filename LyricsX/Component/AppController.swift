import AppKit
import Combine
import Regex
import OpenCC
import MusicPlayer
import LyricsXFoundation
import WidgetKit
import LyricsXWidgetShared

/// What a "switch to the next lyrics candidate" request ended up doing.
enum LyricsCandidateSwitchOutcome {
    /// Moved onto another candidate. `position` is 1-based, for display.
    case switched(position: Int, total: Int, service: String?)
    /// The online pool held nothing to switch to — the usual state for a track
    /// whose lyrics came from a local source, which does not run a search — so
    /// one is running now to fill it.
    case searching
    /// That search finished without turning up anything other than what is
    /// already on screen.
    case exhausted
    /// Nothing is playing.
    case unavailable
}

extension Notification.Name {
    static let lyricsCandidatesDidChange = Notification.Name("LyricsX.lyricsCandidatesDidChange")
}

@Loggable(subsystem: "com.JH.LyricsX.AppController", category: "AppController")
final class AppController: NSObject {
    static let shared = AppController()

    enum LocalLyricsSource: Equatable {
        case embedded
        case file(URL)
        /// One menu option for any LyricsX-managed source, whether it is a
        /// saved library file or the selected online result held in memory.
        case lyricsX
    }

    struct LocalLyricsChoice {
        let track: MusicTrack
        let source: LocalLyricsSource
        let title: String
        var embeddedContents: String? = nil
        /// The preferred saved file for a `.lyricsX` choice. A memory-backed
        /// online choice leaves this nil and supplies `memoryLyrics` instead.
        var lyricsXFileURL: URL? = nil
        var memoryLyrics: Lyrics? = nil
    }

    @Published private(set) var currentLocalLyricsSource: LocalLyricsSource?

    var lyricsManager: LyricsProvider
    private let localLyricsIOQueue = DispatchQueue(label: "LocalLyricsIO", qos: .userInitiated)
    // A slow scripting-bridge read for one track must not hold up the quick
    // adjacent-file check for the next track.
    private let localLyricsRefreshQueue = DispatchQueue(
        label: "LocalLyricsRefresh", qos: .userInitiated, attributes: .concurrent
    )
    // Lyrics can also be replaced by main-thread menu/search actions. Protect
    // invalidation and the final local-load commit as one operation.
    private let localLyricsSelectionLock = NSRecursiveLock()
    private var localLyricsSelectionID = UUID()
    private let localLyricsMemoryLock = NSLock()
    private var localLyricsSelectedOnlineByTrackID: [String: Lyrics] = [:]

    @Published var currentLyrics: Lyrics? {
        willSet {
            localLyricsSelectionLock.lock()
            localLyricsSelectionID = UUID()
            if newValue !== currentLyrics {
                currentLocalLyricsSource = nil
            }
            willChangeValue(forKey: "lyricsOffset")
            currentLineIndex = nil
        }
        didSet {
            defer { localLyricsSelectionLock.unlock() }
            didChangeValue(forKey: "lyricsOffset")
            scheduleCurrentLineCheck()
        }
    }

    @Published var currentLineIndex: Int?

    var searchRequest: LyricsSearchRequest?
    var searchTask: Task<Void, Never>?

    /// Every online candidate the current track's search produced, ordered by
    /// the same relation the manual search panel sorts its list by. Local
    /// embedded and file lyrics are kept in the Local Lyrics submenu instead.
    /// The display logic in `lyricsReceived` picks the top of this pool on its
    /// own; `advanceToNextLyricsCandidate` walks it by hand when that pick was
    /// wrong.
    private(set) var lyricsCandidatePool = PriorityOrderedCandidatePool<Lyrics>(hasHigherPriority: lyricsHasHigherPriority)

    /// The track the pool was filled for. A search that outlives a track change
    /// would otherwise drop its results into the next track's pool.
    private var candidatePoolTrackId: String?

    /// Set once the user picks a candidate by hand. While pinned, arriving
    /// results still enter the pool but never replace `currentLyrics` —
    /// otherwise a late high-priority result would yank the screen straight
    /// back off the user's pick.
    private var candidateSelectionIsPinned = false

    private var candidateReplenishTask: Task<Void, Never>?
    /// Invalidates a replenish task even when its provider does not promptly
    /// observe Task cancellation. Results from an older generation must never
    /// change the current track or replace a later local selection.
    private var candidateReplenishID = UUID()

    private func withLyricsSelectionLock<T>(_ body: () -> T) -> T {
        localLyricsSelectionLock.lock()
        defer { localLyricsSelectionLock.unlock() }
        return body()
    }

    private struct UserPickedCandidateCommit {
        let lyrics: Lyrics
        let track: MusicTrack
        let position: Int
        let total: Int
        let service: String?
    }

    /// What a "next candidate" request ended up doing. Published rather than
    /// returned because the replenish path resolves asynchronously, and both
    /// paths should reach the same one piece of UI.
    let lyricsCandidateSwitchOutcomes = PassthroughSubject<LyricsCandidateSwitchOutcome, Never>()

    private var previousPlaybackState: PlaybackState?

    private var cancelBag = Set<AnyCancellable>()

    private let widgetDataStore = WidgetDataStore(groupIdentifier: lyricsXGroupIdentifier)

    @objc dynamic var lyricsOffset: Int {
        get {
            return currentLyrics?.offset ?? 0
        }
        set {
            currentLyrics?.offset = newValue
            currentLyrics?.metadata.needsPersist = true
            scheduleCurrentLineCheck()
        }
    }

    private override init() {
        self.lyricsManager = LyricsProviders.Group()
        super.init()
        // Dedup by track id (MusicTrack.Equatable compares ids) so that
        // SystemMedia's artwork-only updates within the same song do not
        // re-trigger lyrics search.
        selectedPlayer.currentTrackWillChange
            .removeDuplicates()
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .invoke(AppController.currentTrackChanged, weaklyOn: self)
            .store(in: &cancelBag)
        selectedPlayer.playbackStateWillChange
            .receive(on: DispatchQueue.lyricsDisplay)
            .invoke(AppController.playbackStateChanged, weaklyOn: self)
            .store(in: &cancelBag)
        // `lyrics.adjustedTimeDelay` reads `globalLyricsOffset` dynamically, so a
        // change must reschedule `currentLineIndex`. Per-track offset is handled
        // by the `lyricsOffset` setter; the global key has no setter path here.
        defaults.publisher(for: [.globalLyricsOffset])
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .sink { [weak self] in
                self?.scheduleCurrentLineCheck()
            }
            .store(in: &cancelBag)

        // Rebuild the provider group when something that gates the Apple Music
        // name-recovery plugin changes. The plugin is mounted only when the
        // user toggle is on AND the active player is Apple Music, so we have
        // to react to both the preference and any change in the active player:
        //
        // - the recovery toggle itself;
        // - preferred-player switch in General settings;
        // - NowPlaying / SystemMedia routing to a different app's track
        //   (e.g. user starts playing in Apple Music while another player
        //   was previously the active source).
        Publishers.MergeMany(
            defaults.publisher(for: [.appleMusicNameRecoveryEnabled]).signal().eraseToAnyPublisher(),
            defaults.publisher(for: [.preferredPlayerIndex, .useSystemWideNowPlaying, .systemWideNowPlayingAppList]).signal().eraseToAnyPublisher(),
            selectedPlayer.currentTrackWillChange.signal().eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .map { (defaults[.appleMusicNameRecoveryEnabled], selectedPlayer.name) }
        .removeDuplicates(by: ==)
        .sink { [weak self] _ in
            Task { @MainActor in await self?.updateLyricsManager() }
        }
        .store(in: &cancelBag)

        workspaceNC.publisher(for: NSWorkspace.didTerminateApplicationNotification, object: nil)
            .sink { notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let bundleID = application.bundleIdentifier
                if defaults[.launchAndQuitWithPlayer], (selectedPlayer.designatedPlayer as? MusicPlayers.Scriptable)?.playerBundleID == bundleID {
                    NSApplication.shared.terminate(self)
                }
            }.store(in: &cancelBag)

        // Widget data bridge.
        //
        // Lyrics/track change and playback state change (play/pause/seek)
        // alter the timeline structure, so they rebuild the timeline.
        //
        // Line index change is handled separately and only refreshes the
        // dataStore — the timeline already contains future entries that
        // drive the next line transition autonomously, so a reload here
        // would only add WidgetKit scheduling latency (~hundreds of ms,
        // the visible "widget lyrics lag" before this change).
        $currentLyrics
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .sink { [weak self] in
                guard let self = self else { return }
                reloadWidgetTimeline()
            }
            .store(in: &cancelBag)

        // Pause is observed as a single, clean willChange event — react
        // immediately. Resume from MusicPlayer's SystemMedia/mediaremote-
        // adapter backend, in contrast, fires two willChange events
        // 160ms–900ms apart: the first carries a stale `time` (off by
        // several seconds), the second carries the real position. Naively
        // reloading on the first event makes the widget fetch a timeline
        // built from the wrong `time`, and WidgetKit's reload throttle
        // can push the corrective fetch out by several seconds. So we
        // route the two cases separately: the resume path is debounced
        // long enough to absorb the longest jitter window we've measured,
        // while the pause path stays on the fast `receive(on:)` route.
        selectedPlayer.playbackStateWillChange
            .filter { !$0.isPlaying }
            .receive(on: DispatchQueue.lyricsDisplay)
            .sink { [weak self] state in
                guard let self = self else { return }
                reloadWidgetTimeline(playbackState: state)
            }
            .store(in: &cancelBag)

        selectedPlayer.playbackStateWillChange
            .filter { $0.isPlaying }
            .debounce(for: .milliseconds(1000), scheduler: DispatchQueue.lyricsDisplay)
            .sink { [weak self] state in
                guard let self = self else { return }
                reloadWidgetTimeline(playbackState: state)
            }
            .store(in: &cancelBag)

        $currentLineIndex
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .sink { [weak self] in
                guard let self = self else { return }
                updateWidgetSnapshot()
            }
            .store(in: &cancelBag)

        currentTrackChanged()

        Task { await updateLyricsManager() }
    }

    @MainActor
    func updateLyricsManager() async {
        let musixmatchToken = defaults[.musixmatchToken].flatMap { $0.isEmpty ? nil : $0 }
        var providers: [LyricsProvider] = [
            LyricsProviders.Service.netease.create(),
            LyricsProviders.Service.qq.create(),
            LyricsProviders.Service.kugou.create(),
            LyricsProviders.Service.lrclib.create(),
            LyricsProviders.Service.musixmatch.create(.init(usertoken: musixmatchToken)),
        ]
        // Route A: official Apple Music syllable-lyrics via amp-api. Only
        // registered when the user supplied a `media-user-token` AND the
        // provider can actually reach amp-api with it (`isAuthorized` hits
        // `/v1/me/storefront` once, cached per-instance) — without that,
        // every fetch would 401 and pollute the result stream.
        if #available(macOS 12.0, *),
           let token = defaults[.appleMusicMediaUserToken],
           !token.isEmpty {
            let appleMusicProvider = LyricsProviders.Service.appleMusic.create(
                .init(
                    mediaUserToken: token,
                    storefrontOverride: defaults[.appleMusicStorefront].flatMap { $0.isEmpty ? nil : $0 },
                    languageOverride: defaults[.appleMusicLanguage].flatMap { $0.isEmpty ? nil : $0 }
                )
            )
            if await appleMusicProvider.isAuthorized {
                providers.append(appleMusicProvider)
            }
        }
        // Route B: for Apple Music tracks, a search plugin recovers the
        // native-script name via the Apple Music catalog so the providers
        // can match it. The plugin runs upstream of the providers — it
        // widens the search, it is not a lyrics source itself.
        var plugins: [LyricsSearchRequestPlugin] = []
        if #available(macOS 12.0, *), defaults[.appleMusicNameRecoveryEnabled], selectedPlayer.name == .appleMusic {
            plugins.append(AppleMusicNameRecoveryPlugin())
        }
        lyricsManager = LyricsProviders.Group(providers: providers, plugins: plugins)
    }

    var currentLineCheckSchedule: Cancellable?

    // Reschedule on every publish. The schedule path is cheap (timer
    // cancel + binary search + new timer, ~10µs per call) and any form
    // of dedup here would let the previously scheduled timer keep
    // firing on a stale wallclock anchor, lagging or leading the real
    // playback boundary. Passing the anchor-derived `PlaybackState`
    // from the publish through to the schedule, instead of re-reading
    // the cached `selectedPlayer` value, is preserved by routing every
    // event through here.
    private func playbackStateChanged(_ playbackState: PlaybackState) {
        let shouldPreserveCurrentLine = currentLyrics != nil &&
            currentLineIndex != nil &&
            selectedPlayer.currentTrack != nil &&
            LyricsPlaybackPositionPolicy.shouldPreserveCurrentLine(
                previousState: previousPlaybackState,
                newState: playbackState
            )
        previousPlaybackState = playbackState

        // The zero-time pause publish carries no usable anchor, so there is
        // nothing to reschedule against: drop the pending timer and leave
        // `currentLineIndex` where it is until a state with a real time
        // arrives.
        if shouldPreserveCurrentLine {
            currentLineCheckSchedule?.cancel()
            currentLineCheckSchedule = nil
            return
        }
        scheduleCurrentLineCheck(playbackState: playbackState)
    }

    func scheduleCurrentLineCheck(playbackState: PlaybackState? = nil) {
        currentLineCheckSchedule?.cancel()
        guard let lyrics = currentLyrics else {
            return
        }
        // Use the anchor-derived `PlaybackState.time` rather than the
        // delegate-cached `selectedPlayer.playbackTime`. The latter can lag
        // around repeat-one wrap and track-change boundaries, leaving the
        // lyric index stalled while playback has actually moved on.
        let resolvedPlaybackState = playbackState ?? MusicPlayers.Selected.shared.playbackState
        let trackDuration = selectedPlayer.currentTrack?.duration
        let playbackTime = resolvedPlaybackState.lyricsDisplayTime(trackDuration: trackDuration)
        let (index, next) = lyrics[playbackTime + lyrics.adjustedTimeDelay]
        if currentLineIndex != index {
            currentLineIndex = index
        }
        let q = DispatchQueue.lyricsDisplay
        if let next = next, resolvedPlaybackState.isPlaying {
            let dt = max(0, lyrics.lines[next].position - playbackTime - lyrics.adjustedTimeDelay)
            currentLineCheckSchedule = q.schedule(
                after: q.now.advanced(by: .seconds(dt)),
                interval: .seconds(42),
                tolerance: .milliseconds(20)
            ) { [unowned self] in
                self.scheduleCurrentLineCheck()
            }
        } else if resolvedPlaybackState.isPlaying {
            // Past the last lyric line but still playing: keep a recovery edge
            // for missed state publishes, and snap the next check to the track
            // duration plus a short confirmation window when it is closer than
            // the regular polling interval.
            // Combined with `lyricsDisplayTime(trackDuration:)`, this lets
            // repeat-one wrap back to the opening lyric without waiting for the
            // next one-second poll when the player keeps the old playback anchor.
            let nextCheckDelay = Self.lastLineCheckDelay(playbackTime: playbackTime, trackDuration: trackDuration)
            let tolerance: DispatchQueue.SchedulerTimeType.Stride = nextCheckDelay < 1 ? .milliseconds(20) : .milliseconds(100)
            currentLineCheckSchedule = q.schedule(
                after: q.now.advanced(by: .seconds(nextCheckDelay)),
                interval: .seconds(1),
                tolerance: tolerance
            ) { [unowned self] in
                self.scheduleCurrentLineCheck()
            }
        }
    }

    private static func lastLineCheckDelay(playbackTime: TimeInterval, trackDuration: TimeInterval?) -> TimeInterval {
        guard playbackTime.isFinite,
              let trackDuration = trackDuration,
              trackDuration.isFinite,
              trackDuration > 0 else {
            return 1
        }
        let wrapCheckTime = trackDuration + PlaybackState.lyricsRepeatWrapGracePeriod
        guard wrapCheckTime > playbackTime else {
            return 1
        }
        return min(1, wrapCheckTime - playbackTime)
    }

    func writeToiTunes(overwrite: Bool) {
        guard selectedPlayer.name == .appleMusic,
              let currentLyrics = currentLyrics,
              let sbTrack = selectedPlayer.currentTrack?.originalTrack,
              overwrite || (sbTrack.value(forKey: "lyrics") as! String?)?.isEmpty != false else {
            return
        }

        let content: String
        if defaults[.writeiTunesConvertToPlainLRC] {
            // For plain LRC export, preserve the legacy LRC formatting but still respect
            // the Chinese conversion setting for consistency with the non-plain branch.
            var legacy = currentLyrics.legacyDescription
            if let converter = ChineseConverter.shared {
                legacy = converter.convert(legacy)
            }
            // Note: translations are intentionally not appended for plain LRC export,
            // even when `writeiTunesWithTranslation` is enabled, to keep the legacy
            // LRC output single-line per timestamp.
            content = legacy
        } else {
            content = currentLyrics.lines.map { line -> String in
                var content = line.content
                if let converter = ChineseConverter.shared {
                    content = converter.convert(content)
                }
                if defaults[.writeiTunesWithTranslation] {
                    // TODO: tagged translation
                    let code = currentLyrics.metadata.translationLanguages.first
                    if var translation = line.attachments[.translation(languageCode: code)] {
                        if let converter = ChineseConverter.shared {
                            translation = converter.convert(translation)
                        }
                        content += "\n" + translation
                    }
                }
                return content
            }.joined(separator: "\n")
        }
        // swiftlint:disable:next force_try
        let regex = Regex(#"\n{3,}"#)
        let replaced = content.replacingMatches(of: regex, with: "\n\n")
        sbTrack.setValue(replaced, forKey: "lyrics")
    }

    func currentTrackChanged() {
        persistCurrentLyrics()
        withLyricsSelectionLock {
            searchTask?.cancel()
            searchTask = nil
            searchRequest = nil
        }
        resetLyricsCandidatePool()
        clearSelectedOnlineLyrics()
        currentLyrics = nil
        currentLineIndex = nil
        let selectionID = withLyricsSelectionLock { localLyricsSelectionID }
        guard let track = selectedPlayer.currentTrack else {
            Task { await ArtworkSimilarityScorer.shared.updateNowPlaying(image: nil, trackId: nil) }
            return
        }
        withLyricsSelectionLock {
            candidatePoolTrackId = track.id
        }
        let nowPlayingImage = track.artwork
        let nowPlayingId = track.id
        Task { await ArtworkSimilarityScorer.shared.updateNowPlaying(image: nowPlayingImage, trackId: nowPlayingId) }
        // FIXME: deal with optional value
        let title = track.title ?? ""
        let artist = track.artist ?? ""

        guard !defaults[.noSearchingTrackIds].contains(track.id) else {
            return
        }

        // A candidate the user switched to by hand outranks every automatic
        // lookup below — including lyrics embedded in the audio file and lyrics
        // sitting beside it, either of which would otherwise win on order alone
        // and silently undo the choice.
        if let overrideURL = userSelectedLyricsURL(forTrackId: track.id),
           let lyrics = loadLyrics(
               at: overrideURL,
               securityScopedURL: defaults.lyricsSecurityScopedDirectory(containing: overrideURL),
               title: title,
               artist: artist
           ) {
            let source: LocalLyricsSource = isLyricsXManagedFile(overrideURL) ? .lyricsX : .file(overrideURL)
            guard commitTrackLookupLyrics(lyrics, source: source, for: track, selectionID: selectionID) != nil else {
                return
            }
            return
        }

        guard defaults[.loadLyricsBesideTrack] else {
            continueTrackLookup(track, embeddedLyrics: nil, musicFileURL: nil, selectionID: selectionID)
            return
        }
        localLyricsRefreshQueue.async {
            let embedded = track.lyrics
            let fileURL = track.localFileURL
            DispatchQueue.lyricsDisplay.async {
                let isCurrent = self.withLyricsSelectionLock {
                    self.localLyricsSelectionID == selectionID
                        && selectedPlayer.currentTrack?.id == track.id
                }
                guard isCurrent else { return }
                self.continueTrackLookup(
                    track,
                    embeddedLyrics: embedded,
                    musicFileURL: fileURL,
                    selectionID: selectionID
                )
            }
        }
    }

    private func isCurrentTrackLookup(_ track: MusicTrack, selectionID: UUID?) -> Bool {
        withLyricsSelectionLock {
            selectedPlayer.currentTrack?.id == track.id
                && (selectionID == nil || localLyricsSelectionID == selectionID)
        }
    }

    @discardableResult
    private func commitTrackLookupLyrics(
        _ lyrics: Lyrics,
        source: LocalLyricsSource,
        for track: MusicTrack,
        selectionID: UUID?
    ) -> UUID? {
        withLyricsSelectionLock {
            guard selectedPlayer.currentTrack?.id == track.id,
                  (selectionID == nil || localLyricsSelectionID == selectionID) else {
                return nil
            }
            currentLyrics = lyrics
            currentLocalLyricsSource = source
            return localLyricsSelectionID
        }
    }

    private func continueTrackLookup(
        _ track: MusicTrack,
        embeddedLyrics: String?,
        musicFileURL: URL?,
        selectionID: UUID? = nil
    ) {
        var selectionID = selectionID
        guard isCurrentTrackLookup(track, selectionID: selectionID) else { return }
        let title = track.title ?? ""
        let artist = track.artist ?? ""
        var candidateLyricsFiles: [LyricsLookupCandidateFile] = []

        if defaults[.loadLyricsBesideTrack] {
            if let embeddedLyrics, !embeddedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let lyrics = Lyrics(embeddedLyrics) {
                    if lyrics.metadata.title == nil || lyrics.metadata.title?.isEmpty == true {
                        lyrics.metadata.title = title
                    }
                    if lyrics.metadata.artist == nil || lyrics.metadata.artist?.isEmpty == true {
                        lyrics.metadata.artist = artist
                    }
                    lyrics.applyQQMusicKanaFurigana()
                    lyrics.filtrate()
                    lyrics.recognizeLanguage()
                    guard commitTrackLookupLyrics(lyrics, source: .embedded, for: track, selectionID: selectionID) != nil else {
                        return
                    }
                    return
                }
            }
            if let besideTrackBaseURL = musicFileURL?.deletingPathExtension() {
                candidateLyricsFiles += [
                    LyricsLookupCandidateFile(
                        fileURL: besideTrackBaseURL.appendingPathExtension("lrcx"),
                        isSecurityScoped: false,
                        allowsFurtherSearching: false,
                        isLibraryFile: false
                    ),
                    LyricsLookupCandidateFile(
                        fileURL: besideTrackBaseURL.appendingPathExtension("lrc"),
                        isSecurityScoped: false,
                        allowsFurtherSearching: false,
                        isLibraryFile: false
                    ),
                ]
            }
        }

        // The library is the only layer the "ignore saved lyrics" switch covers:
        // everything above is either the user's own file or the user's own
        // choice, and neither is a cache to be bypassed. It is read even when
        // the switch is on, because the file itself says whether the switch
        // applies to it — and that can only be seen after reading it.
        candidateLyricsFiles += librarySearchFiles(title: title, artist: artist)

        for candidateFile in candidateLyricsFiles {
            if let lyrics = loadLyrics(
                at: candidateFile.fileURL,
                securityScopedURL: candidateFile.isSecurityScoped ? candidateFile.fileURL : nil,
                title: title,
                artist: artist
            ) {
                // The switch means "do not trust what LyricsX saved for itself".
                // Lyrics the user applied by hand were never LyricsX's own
                // decision, so they stay in play.
                if candidateFile.isLibraryFile,
                   defaults[.ignoreCachedLyricsLibrary],
                   !lyrics.isUserPicked {
                    continue
                }
                let source: LocalLyricsSource = candidateFile.isLibraryFile ? .lyricsX : .file(candidateFile.fileURL)
                guard let committedSelectionID = commitTrackLookupLyrics(
                    lyrics,
                    source: source,
                    for: track,
                    selectionID: selectionID
                ) else {
                    return
                }
                if candidateFile.allowsFurtherSearching {
                    selectionID = committedSelectionID
                    break
                } else {
                    return
                }
            }
        }

        if let album = track.album, defaults[.noSearchingAlbumNames].contains(album) {
            return
        }

        guard isCurrentTrackLookup(track, selectionID: selectionID) else { return }
        let request = makeLyricsSearchRequest(for: track)
        let didStartSearch = withLyricsSelectionLock { () -> Bool in
            guard selectedPlayer.currentTrack?.id == track.id,
                  (selectionID == nil || localLyricsSelectionID == selectionID) else {
                return false
            }
            searchRequest = request
            searchTask = Task { @MainActor in
                await runLyricsSearch(
                    request,
                    for: track,
                    title: title,
                    artist: artist
                )
            }
            return true
        }
        guard didStartSearch else { return }
    }

    @MainActor
    private func runLyricsSearch(
        _ request: LyricsSearchRequest,
        for track: MusicTrack,
        title: String,
        artist: String
    ) async {
        do {
            // Accept the first arrived lyrics immediately,
            // but keep collecting for a short window to allow higher-priority providers,
            // which might be slower, to replace it.
            let window = defaults[.lyricsPriorityWindow] ?? 5 // seconds
            var firstReceived = false
            var collectionStart: Date?

            for try await lyrics in lyricsManager.lyrics(for: request) {
                try Task.checkCancellation()
                if !firstReceived {
                    lyricsReceived(lyrics: lyrics)
                    let displayedLyrics = withLyricsSelectionLock { currentLyrics }
                    if let current = displayedLyrics, current === lyrics {
                        firstReceived = true
                        collectionStart = Date()
                    }
                    continue
                }

                // Route B name-recovery results are slower than the direct
                // providers by design, so they are exempt from the priority
                // window — otherwise they would always arrive too late.
                let lyricsIsRecovered = lyrics.isFromSearchPlugin
                let withinWindow = collectionStart.map { Date().timeIntervalSince($0) <= window } ?? false

                // Past the window and not a recovery result: it may no
                // longer take the screen (no late swap from the direct
                // providers), but it is still a candidate the user can
                // switch onto by hand — so it goes through the normal path
                // and into the pool, just flagged as ineligible to display.
                lyrics.arrivedAfterPriorityWindow = !(withinWindow || lyricsIsRecovered)
                lyricsReceived(lyrics: lyrics)
            }

            try Task.checkCancellation()
            guard withLyricsSelectionLock({
                searchRequest == request && selectedPlayer.currentTrack?.id == track.id
            }) else {
                return
            }
            loadLibraryLyricsIfSearchFoundNothing(
                for: track,
                title: title,
                artist: artist,
                expectedSearchRequest: request
            )

            if defaults[.writeToiTunesAutomatically] {
                writeToiTunes(overwrite: true)
            }
        } catch is CancellationError {
            // Search was cancelled due to track change
        } catch {
            print("Failed to fetch lyrics: \(error.localizedDescription)")
            // The case the fallback exists for: every provider failed, which
            // offline is the normal outcome rather than the exception.
            guard withLyricsSelectionLock({
                searchRequest == request && selectedPlayer.currentTrack?.id == track.id
            }) else {
                return
            }
            loadLibraryLyricsIfSearchFoundNothing(
                for: track,
                title: title,
                artist: artist,
                expectedSearchRequest: request
            )
        }
    }

    /// One file an automatic lookup may read, and what reading it implies.
    private struct LyricsLookupCandidateFile {
        let fileURL: URL
        let isSecurityScoped: Bool
        /// A plain `.lrc` is displayed but does not end the lookup: it carries
        /// none of the LRCX extras, so a search still runs to try to better it.
        let allowsFurtherSearching: Bool
        /// A file from LyricsX's own library, which the bypass switch may reject
        /// once it has been read and found to carry no user-pick mark.
        let isLibraryFile: Bool
    }

    private func isLyricsXManagedFile(_ fileURL: URL) -> Bool {
        LyricsStoragePolicy.isManagedLibraryFile(
            fileURL,
            defaultDirectoryURL: defaults.lyricsDefaultSavingDirectory,
            customDirectoryURL: defaults.lyricsCustomSavingPath
        )
    }

    private func lyricsXFileCandidates(for track: MusicTrack, preferredURL: URL?) -> [LyricsLookupCandidateFile] {
        let candidates = librarySearchFiles(title: track.title ?? "", artist: track.artist ?? "")
        guard let preferredURL,
              let preferred = candidates.first(where: { $0.fileURL == preferredURL }) else {
            return candidates
        }
        return [preferred] + candidates.filter { $0.fileURL != preferred.fileURL }
    }

    /// The saved-lyrics library, in lookup order: every spelling of the name as
    /// LRCX first, then every spelling as plain LRC.
    ///
    /// Both spellings, because `persist()` writes the canonical (trimmed) name
    /// while libraries from older releases carry an untrimmed one. Reading only
    /// the legacy spelling leaves a file this very session just saved
    /// unreachable whenever the metadata has surrounding whitespace — harmless
    /// while a cache hit merely saved a search, but not once the search-fallback
    /// path below depends on reading back what was written. For metadata
    /// without surrounding whitespace the two spellings coincide and this
    /// returns exactly the two files it always did.
    private func librarySearchFiles(title: String, artist: String) -> [LyricsLookupCandidateFile] {
        let (directoryURL, isSecurityScoped) = defaults.lyricsSavingPath()
        let baseURLs = LyricsStoragePolicy
            .libraryFileBaseNameCandidates(title: title, artist: artist)
            .map { directoryURL.appendingPathComponent($0) }
        return baseURLs.map {
            LyricsLookupCandidateFile(
                fileURL: $0.appendingPathExtension("lrcx"),
                isSecurityScoped: isSecurityScoped,
                allowsFurtherSearching: false,
                isLibraryFile: true
            )
        } + baseURLs.map {
            LyricsLookupCandidateFile(
                fileURL: $0.appendingPathExtension("lrc"),
                isSecurityScoped: isSecurityScoped,
                allowsFurtherSearching: true,
                isLibraryFile: true
            )
        }
    }

    /// Reads the library that `ignoreCachedLyricsLibrary` told the lookup to
    /// skip — but only when the search came back empty-handed. Without this,
    /// "always fetch fresh" would degrade into "no lyrics at all" whenever the
    /// network is down, which is plainly worse than a possibly stale file.
    private func loadLibraryLyricsIfSearchFoundNothing(
        for track: MusicTrack,
        title: String,
        artist: String,
        expectedSearchRequest: LyricsSearchRequest? = nil
    ) {
        guard defaults[.ignoreCachedLyricsLibrary] else {
            return
        }
        // The search may well have outlived the track it was started for.
        let canAttemptLookup = withLyricsSelectionLock {
            currentLyrics == nil && selectedPlayer.currentTrack?.id == track.id
        }
        guard canAttemptLookup else { return }
        for candidateFile in librarySearchFiles(title: title, artist: artist) {
            if let lyrics = loadLyrics(
                at: candidateFile.fileURL,
                securityScopedURL: candidateFile.isSecurityScoped ? candidateFile.fileURL : nil,
                title: title,
                artist: artist
            ) {
                let didCommit = withLyricsSelectionLock {
                    guard selectedPlayer.currentTrack?.id == track.id,
                          currentLyrics == nil,
                          (expectedSearchRequest == nil || searchRequest == expectedSearchRequest) else {
                        return false
                    }
                    currentLyrics = lyrics
                    currentLocalLyricsSource = .lyricsX
                    return true
                }
                if didCommit {
                    return
                }
            }
        }
    }

    // MARK: LyricsSourceDelegate

    func lyricsReceived(lyrics: Lyrics) {
        guard let track = selectedPlayer.currentTrack,
              prepareLyricsCandidate(lyrics, for: track, allowsAutomaticReplacement: true) else {
            return
        }

        let shouldPublish = withLyricsSelectionLock { () -> Bool in
            guard selectedPlayer.currentTrack?.id == track.id,
                  let request = searchRequest,
                  lyrics.metadata.request?.id == request.id,
                  LyricsDisplayEligibilityPolicy.shouldReplaceDisplayed(
                      selectionIsPinned: candidateSelectionIsPinned,
                      candidateArrivedAfterPriorityWindow: lyrics.arrivedAfterPriorityWindow,
                      displayedIsRecovered: currentLyrics?.isFromSearchPlugin,
                      candidateIsRecovered: lyrics.isFromSearchPlugin,
                      candidateOutranksDisplayed: currentLyrics.map {
                          lyricsHasHigherPriority(lyrics, over: $0)
                      } ?? true
                  ) else {
                return false
            }

            currentLyrics = lyrics
            lyricsCandidatePool.selectCandidate(identicalTo: lyrics)
            // The result that wins the automatic display decision is the one
            // online candidate shown in the local menu. Other provider results
            // remain available only through the candidate pool.
            return markSelectedOnlineLyricsState(lyrics, for: track.id)
        }
        if shouldPublish {
            postLyricsCandidatesDidChange(for: track.id)
        }
    }

    // MARK: Lyrics Candidates

    private func resetLyricsCandidatePool() {
        withLyricsSelectionLock {
            candidateReplenishID = UUID()
            candidateReplenishTask?.cancel()
            candidateReplenishTask = nil
            lyricsCandidatePool.removeAll()
            candidateSelectionIsPinned = false
            candidatePoolTrackId = nil
        }
    }

    private func cancelCandidateReplenishSearch() {
        withLyricsSelectionLock {
            candidateReplenishID = UUID()
            candidateReplenishTask?.cancel()
            candidateReplenishTask = nil
        }
    }

    private func clearSelectedOnlineLyrics() {
        localLyricsMemoryLock.lock()
        localLyricsSelectedOnlineByTrackID.removeAll()
        localLyricsMemoryLock.unlock()
    }

    @discardableResult
    private func rememberSelectedOnlineLyrics(_ lyrics: Lyrics, for trackID: String) -> Bool {
        // A local file or embedded result has neither provider request nor
        // service metadata. Provider results enter the menu's online slot only
        // when this method is called after one has been selected for display,
        // either automatically or by the user; other arrivals stay in the pool.
        guard isOnlineLyricsCandidate(lyrics) else {
            return false
        }
        localLyricsMemoryLock.lock()
        localLyricsSelectedOnlineByTrackID[trackID] = lyrics
        localLyricsMemoryLock.unlock()
        return true
    }

    @discardableResult
    private func markSelectedOnlineLyricsState(_ lyrics: Lyrics, for trackID: String) -> Bool {
        guard rememberSelectedOnlineLyrics(lyrics, for: trackID) else { return false }
        currentLocalLyricsSource = .lyricsX
        return true
    }

    private func postLyricsCandidatesDidChange(for trackID: String) {
        NotificationCenter.default.post(
            name: .lyricsCandidatesDidChange,
            object: self,
            userInfo: ["trackID": trackID]
        )
    }

    private func publishSelectedOnlineLyrics(_ lyrics: Lyrics, for trackID: String) {
        let didMark = withLyricsSelectionLock {
            markSelectedOnlineLyricsState(lyrics, for: trackID)
        }
        if didMark {
            postLyricsCandidatesDidChange(for: trackID)
        }
    }

    private func selectedOnlineLyrics(for trackID: String) -> Lyrics? {
        localLyricsMemoryLock.lock()
        defer { localLyricsMemoryLock.unlock() }
        return localLyricsSelectedOnlineByTrackID[trackID]
    }

    /// The next-candidate shortcut is an online-search feature. Local lyrics
    /// are intentionally kept out of this pool and remain available through
    /// the Local Lyrics submenu instead.
    private func isOnlineLyricsCandidate(_ lyrics: Lyrics) -> Bool {
        lyrics.metadata.request != nil || lyrics.metadata.service != nil
    }

    /// Validates, normalizes, and stores one online result. Automatic display
    /// is deliberately kept outside this method so a replenish search can
    /// collect candidates without changing what is currently on screen.
    @discardableResult
    private func prepareLyricsCandidate(
        _ lyrics: Lyrics,
        for track: MusicTrack,
        allowsAutomaticReplacement: Bool
    ) -> Bool {
        // Match by session id, not request equality: Route B's plugin
        // expands one search into several requests with different search
        // terms but the same session id, and all of them belong here.
        guard let lyricRequestID = lyrics.metadata.request?.id,
              withLyricsSelectionLock({
                  searchRequest?.id == lyricRequestID && candidatePoolTrackId == track.id
              }) else {
            return false
        }
        if defaults[.strictSearchEnabled], !lyrics.isMatched() {
            return false
        }

        lyrics.associateWithTrack(track)
        lyrics.applyQQMusicKanaFurigana()
        lyrics.filtrate()
        lyrics.recognizeLanguage()
        lyrics.metadata.needsPersist = true

        // Entering the pool is unconditional: losing the display contest says
        // nothing about whether the user might want this candidate. Only the
        // caller's display policy decides whether it goes on screen.
        guard withLyricsSelectionLock({ insertIntoLyricsCandidatePool(lyrics, for: track) }) else {
            return false
        }
        scheduleArtworkScoring(
            for: lyrics,
            against: track,
            allowsAutomaticReplacement: allowsAutomaticReplacement
        )
        return true
    }

    /// Returns whether `lyrics` was taken into the pool. Rejects results that
    /// belong to another track, and duplicates of a candidate already held —
    /// different services routinely return the very same words, and switching
    /// onto an identical copy reads as the shortcut being broken.
    @discardableResult
    private func insertIntoLyricsCandidatePool(_ lyrics: Lyrics, for track: MusicTrack) -> Bool {
        guard candidatePoolTrackId == track.id,
              isOnlineLyricsCandidate(lyrics) else {
            return false
        }
        let fingerprint = lyricsContentFingerprint(lyrics)
        guard !lyricsCandidatePool.contains(where: { lyricsContentFingerprint($0) == fingerprint }) else {
            return false
        }
        lyricsCandidatePool.insert(lyrics)
        return true
    }

    /// Timed line content, which is what actually distinguishes one candidate
    /// from another. Metadata is deliberately left out: the same words fetched
    /// from two services differ in their tags but not in what the user reads.
    private func lyricsContentFingerprint(_ lyrics: Lyrics) -> String {
        lyrics.lines.map { "\($0.position)|\($0.content)" }.joined(separator: "\n")
    }

    /// Moves onto the next candidate for the current track, wrapping around at
    /// the end. Reports what happened through `lyricsCandidateSwitchOutcomes`.
    ///
    /// Left non-isolated to match the rest of this type: `currentLyrics` and
    /// friends are already reached from both `DispatchQueue.lyricsDisplay`
    /// (track changes) and the main queue (search results, user actions).
    func advanceToNextLyricsCandidate() {
        guard let track = selectedPlayer.currentTrack else {
            lyricsCandidateSwitchOutcomes.send(.unavailable)
            return
        }
        let selection = withLyricsSelectionLock {
            (lyricsCandidatePool.candidates, currentLyrics)
        }
        guard let nextCandidate = nextDistinctOnlineCandidate(
            in: selection.0,
            comparedTo: selection.1
        ) else {
            startCandidateReplenishSearch(for: track)
            return
        }
        guard let commit = applyUserPickedCandidate(
            nextCandidate,
            for: track,
            expectedCurrentLyrics: selection.1
        ) else {
            return
        }
        lyricsCandidateSwitchOutcomes.send(.switched(
            position: commit.position,
            total: commit.total,
            service: commit.service
        ))
    }

    /// Advances through the online pool until it finds content different from
    /// what is currently displayed. The current lyrics may be local and thus
    /// absent from the pool, so pool size alone cannot identify a switchable
    /// candidate.
    private func nextDistinctOnlineCandidate(
        in candidates: [Lyrics],
        comparedTo currentLyrics: Lyrics?
    ) -> Lyrics? {
        guard !candidates.isEmpty else { return nil }
        let currentFingerprint = currentLyrics.map(lyricsContentFingerprint)
        let currentIndex = currentLyrics.flatMap { current in
            candidates.firstIndex { $0 === current }
        }
        let startIndex = currentIndex.map { ($0 + 1) % candidates.count } ?? 0
        for offset in 0..<candidates.count {
            let candidate = candidates[(startIndex + offset) % candidates.count]
            if currentFingerprint == nil || lyricsContentFingerprint(candidate) != currentFingerprint {
                return candidate
            }
        }
        return nil
    }

    /// The pool contains only online provider results. A track that currently
    /// displays local lyrics therefore starts with an empty pool and needs a
    /// search before the shortcut can switch to another result.
    private func startCandidateReplenishSearch(for track: MusicTrack) {
        let setup = withLyricsSelectionLock { () -> (LyricsSearchRequest, Lyrics?, UUID)? in
            guard candidateReplenishTask == nil,
                  selectedPlayer.currentTrack?.id == track.id else {
                return nil
            }
            searchTask?.cancel()
            searchTask = nil
            candidatePoolTrackId = track.id
            let onScreenLyrics = currentLyrics
            let request = makeLyricsSearchRequest(for: track)
            searchRequest = request
            let replenishID = UUID()
            candidateReplenishID = replenishID
            return (request, onScreenLyrics, replenishID)
        }
        guard let (request, onScreenLyrics, replenishID) = setup else {
            if withLyricsSelectionLock({ candidateReplenishTask != nil }) {
                lyricsCandidateSwitchOutcomes.send(.searching)
            }
            return
        }
        lyricsCandidateSwitchOutcomes.send(.searching)
        let onScreenFingerprint = onScreenLyrics.map(lyricsContentFingerprint)

        let didInstallTask = withLyricsSelectionLock { () -> Bool in
            guard candidateReplenishID == replenishID,
                  selectedPlayer.currentTrack?.id == track.id else {
                return false
            }
            candidateReplenishTask = Task { @MainActor in
                defer {
                    withLyricsSelectionLock {
                        if candidateReplenishID == replenishID {
                            candidateReplenishTask = nil
                        }
                    }
                }
                var hasSwitched = false
                do {
                    for try await lyrics in lyricsManager.lyrics(for: request) {
                        let isActive = withLyricsSelectionLock {
                            candidateReplenishID == replenishID
                                && selectedPlayer.currentTrack?.id == track.id
                        }
                        guard isActive else { return }
                        guard prepareLyricsCandidate(
                            lyrics,
                            for: track,
                            allowsAutomaticReplacement: false
                        ) else {
                            continue
                        }

                        let candidateSnapshot = withLyricsSelectionLock {
                            lyricsCandidatePool.candidates
                        }
                        guard let firstDifferentCandidate = candidateSnapshot.first(where: { candidate in
                            let candidateFingerprint = lyricsContentFingerprint(candidate)
                            return onScreenFingerprint.map { candidateFingerprint != $0 } ?? true
                        }) else {
                            continue
                        }
                        let commit = withLyricsSelectionLock { () -> UserPickedCandidateCommit? in
                            guard candidateReplenishID == replenishID,
                                  selectedPlayer.currentTrack?.id == track.id,
                                  !hasSwitched else {
                                return nil
                            }
                            guard let commit = commitUserPickedCandidateState(
                                firstDifferentCandidate,
                                for: track,
                                expectedCurrentLyrics: onScreenLyrics
                            ) else {
                                return nil
                            }
                            hasSwitched = true
                            return commit
                        }
                        if let commit {
                            finishUserPickedCandidate(commit)
                            lyricsCandidateSwitchOutcomes.send(.switched(
                                position: commit.position,
                                total: commit.total,
                                service: commit.service
                            ))
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    log("Failed to fetch replenish candidates: \(error.localizedDescription)")
                }
                let shouldReportExhausted = withLyricsSelectionLock {
                    candidateReplenishID == replenishID
                        && selectedPlayer.currentTrack?.id == track.id
                        && !hasSwitched
                }
                if shouldReportExhausted {
                    lyricsCandidateSwitchOutcomes.send(.exhausted)
                }
            }
            return true
        }
        guard didInstallTask else { return }
    }

    /// Puts a hand-picked candidate on screen and makes it stick: pinned
    /// against later arrivals, written to disk, and recorded so the next play
    /// of this track resolves to it too.
    @discardableResult
    private func applyUserPickedCandidate(
        _ lyrics: Lyrics,
        for track: MusicTrack,
        expectedCurrentLyrics: Lyrics? = nil
    ) -> UserPickedCandidateCommit? {
        guard let commit = withLyricsSelectionLock({
            commitUserPickedCandidateState(
                lyrics,
                for: track,
                expectedCurrentLyrics: expectedCurrentLyrics
            )
        }) else {
            return nil
        }
        finishUserPickedCandidate(commit)
        return commit
    }

    private func commitUserPickedCandidateState(
        _ lyrics: Lyrics,
        for track: MusicTrack,
        expectedCurrentLyrics: Lyrics?
    ) -> UserPickedCandidateCommit? {
        guard selectedPlayer.currentTrack?.id == track.id,
              currentLyrics === expectedCurrentLyrics,
              lyricsCandidatePool.contains(where: { $0 === lyrics }),
              isOnlineLyricsCandidate(lyrics) else {
            return nil
        }
        candidateSelectionIsPinned = true
        lyricsCandidatePool.selectCandidate(identicalTo: lyrics)
        lyrics.associateWithTrack(track)
        lyrics.markAsUserPicked(origin: .nextCandidate)
        lyrics.metadata.needsPersist = true
        currentLyrics = lyrics
        guard markSelectedOnlineLyricsState(lyrics, for: track.id) else {
            return nil
        }
        return UserPickedCandidateCommit(
            lyrics: lyrics,
            track: track,
            position: (lyricsCandidatePool.selectedIndex ?? 0) + 1,
            total: lyricsCandidatePool.count,
            service: lyrics.metadata.service
        )
    }

    private func finishUserPickedCandidate(_ commit: UserPickedCandidateCommit) {
        let lyrics = commit.lyrics
        let track = commit.track
        postLyricsCandidatesDidChange(for: track.id)

        // Picking a candidate by hand contradicts any earlier "wrong lyrics"
        // verdict on this track, exactly as choosing one in the search panel does.
        if let index = defaults[.noSearchingTrackIds].firstIndex(of: track.id) {
            defaults[.noSearchingTrackIds].remove(at: index)
        }

        if lyrics.persist() {
            recordUserSelectionIfAutomaticLookupWouldOverrideIt(lyrics, for: track)
        }
        if defaults[.writeToiTunesAutomatically] {
            let isStillCurrent = withLyricsSelectionLock {
                selectedPlayer.currentTrack?.id == track.id && currentLyrics === lyrics
            }
            if isStillCurrent {
                writeToiTunes(overwrite: true)
            }
        }
    }

    /// Adopts a list the user already sorted through — the manual search panel's
    /// results — so the shortcut carries on from what they picked there. The
    /// pool remains online-only even if a caller supplies a local Lyrics value.
    func adoptLyricsCandidates(_ candidates: [Lyrics], selecting selectedCandidate: Lyrics, for track: MusicTrack) {
        cancelCandidateReplenishSearch()
        let didAdopt = withLyricsSelectionLock { () -> Bool in
            candidatePoolTrackId = track.id
            candidateSelectionIsPinned = true
            guard isOnlineLyricsCandidate(selectedCandidate) else {
                lyricsCandidatePool.removeAll()
                return false
            }
            let onlineCandidates = candidates.filter { isOnlineLyricsCandidate($0) }
            lyricsCandidatePool.replaceAll(with: onlineCandidates, selecting: selectedCandidate)
            return true
        }
        if didAdopt {
            publishSelectedOnlineLyrics(selectedCandidate, for: track.id)
        }
    }

    private func userSelectedLyricsURL(forTrackId trackId: String) -> URL? {
        LyricsSelectionOverrideTable
            .filePath(forTrackId: trackId, in: defaults[.lyricsSelectionOverrides])
            .map { URL(fileURLWithPath: $0) }
    }

    /// Records the pick only when the automatic lookup order would otherwise
    /// beat it — an embedded or beside-track file is consulted first, so
    /// without this the choice would last exactly one play.
    private func recordUserSelectionIfAutomaticLookupWouldOverrideIt(_ lyrics: Lyrics, for track: MusicTrack) {
        guard let persistedURL = lyrics.metadata.localURL else {
            return
        }
        guard defaults[.loadLyricsBesideTrack], automaticLookupPrecedes(persistedURL, for: track) else {
            // Nothing is consulted ahead of the file just written, so the plain
            // lookup order already resolves to it.
            defaults[.lyricsSelectionOverrides] = LyricsSelectionOverrideTable.removing(
                trackId: track.id,
                from: defaults[.lyricsSelectionOverrides]
            )
            return
        }
        defaults[.lyricsSelectionOverrides] = LyricsSelectionOverrideTable.recording(
            filePath: persistedURL.path,
            forTrackId: track.id,
            in: defaults[.lyricsSelectionOverrides],
            at: Date()
        )
    }

    private func automaticLookupPrecedes(_ persistedURL: URL, for track: MusicTrack) -> Bool {
        if let embeddedLyrics = track.lyrics,
           !embeddedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        guard let besideTrackBaseURL = track.localFileURL?.deletingPathExtension() else {
            return false
        }
        let besideTrackURLs = [
            besideTrackBaseURL.appendingPathExtension("lrcx"),
            besideTrackBaseURL.appendingPathExtension("lrc"),
        ]
        guard !besideTrackURLs.contains(persistedURL) else {
            return false
        }
        return besideTrackURLs.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func loadLyrics(at fileURL: URL, securityScopedURL: URL?, title: String, artist: String) -> Lyrics? {
        if let securityScopedURL {
            guard securityScopedURL.startAccessingSecurityScopedResource() else {
                return nil
            }
        }
        defer {
            securityScopedURL?.stopAccessingSecurityScopedResource()
        }
        guard let fileContents = try? String(contentsOf: fileURL, encoding: String.Encoding.utf8),
              let lyrics = Lyrics(fileContents) else {
            return nil
        }
        lyrics.metadata.localURL = fileURL
        lyrics.metadata.title = title
        lyrics.metadata.artist = artist
        lyrics.applyQQMusicKanaFurigana()
        lyrics.filtrate()
        lyrics.recognizeLanguage()
        return lyrics
    }

    private func makeLyricsSearchRequest(for track: MusicTrack) -> LyricsSearchRequest {
        let title = track.title ?? ""
        let artist = track.artist ?? ""
        // Strip bracketed suffixes ("(feat. X)", "[Explicit]", "(Remix)", "【现场版】" …)
        // from the search title when the preference is on; providers usually return
        // zero matches for the bracketed form. The full title still drives local
        // cache lookup and the lyrics metadata association.
        let searchTitle = defaults[.stripSearchTitleBracketsEnabled] ? title.strippingBrackets : title
        return LyricsSearchRequest(
            searchTerm: .info(title: searchTitle, artist: artist),
            duration: track.duration ?? 0,
            limit: 5,
            userInfo: [:]
        )
    }

    private func scheduleArtworkScoring(
        for lyrics: Lyrics,
        against track: MusicTrack,
        allowsAutomaticReplacement: Bool
    ) {
        guard defaults[.artworkSimilarityBoostEnabled],
              let url = lyrics.metadata.artworkURL else { return }
        let scoredTrackId = track.id
        let scoredRequest = lyrics.metadata.request
        Task { [weak self] in
            let matched = await ArtworkSimilarityScorer.shared.matches(artworkURL: url)
            guard matched, let self else { return }
            await self.applyArtworkBonus(
                to: lyrics,
                scoredTrackId: scoredTrackId,
                scoredRequest: scoredRequest,
                allowsAutomaticReplacement: allowsAutomaticReplacement
            )
        }
    }

    @MainActor
    private func applyArtworkBonus(
        to lyrics: Lyrics,
        scoredTrackId: String,
        scoredRequest: LyricsSearchRequest?,
        allowsAutomaticReplacement: Bool
    ) {
        let shouldPublish = withLyricsSelectionLock { () -> Bool in
            // Drop the bonus if the user has already moved on to another song —
            // the score was computed against a now-stale artwork.
            guard selectedPlayer.currentTrack?.id == scoredTrackId,
                  let scoredRequest,
                  searchRequest?.id == scoredRequest.id else { return false }
            lyrics.artworkMatchBonus = ArtworkSimilarityScorer.matchBonus
            // The bonus changed this candidate's rank, so the pool has to be
            // re-sorted; the selection stays on whatever object it was pointing at.
            lyricsCandidatePool.resort()
            // The user picked a candidate by hand; a score change must not move it.
            guard !candidateSelectionIsPinned else { return false }
            // A replenish search is collecting options for an explicit user
            // switch. Artwork may reorder those options, but cannot silently
            // replace the lyrics currently on screen.
            guard allowsAutomaticReplacement else { return false }
            // A bonus landing later cannot resurrect a result that already missed
            // the priority window — otherwise late arrivals would take the screen
            // through the artwork path that they are denied through the normal one.
            guard !lyrics.arrivedAfterPriorityWindow else { return false }
            // The lyrics may now outrank the current selection. Re-run the swap
            // check; lyricsReceived's own guards (request id, recovered/non-
            // recovered tier, strict match) still apply.
            guard let current = currentLyrics, current !== lyrics,
                  lyricsHasHigherPriority(lyrics, over: current) else { return false }
            currentLyrics = lyrics
            lyricsCandidatePool.selectCandidate(identicalTo: lyrics)
            // Artwork scoring may select a different online result after the
            // initial search winner. Keep the menu's single LyricsX slot in
            // sync with the candidate now shown on screen.
            return markSelectedOnlineLyricsState(lyrics, for: scoredTrackId)
        }
        if shouldPublish {
            postLyricsCandidatesDidChange(for: scoredTrackId)
        }
    }

    // MARK: Widget Data Bridge

    /// Persist the current snapshot and ask WidgetKit to rebuild the timeline.
    /// Use when the timeline structure must change: track switch, lyrics
    /// (re)load, play/pause toggle, or seek.
    ///
    /// Pass `playbackState` when responding to a `playbackStateWillChange`
    /// emission so the snapshot uses the new value directly, instead of
    /// re-reading `selectedPlayer.playbackState` (which can still hold the
    /// pre-change value during the willSet phase).
    func reloadWidgetTimeline(playbackState: PlaybackState? = nil) {
        guard #available(macOS 14, *) else { return }
        writeWidgetSnapshot(playbackState: playbackState, reloadOnSuccess: true)
    }

    /// Persist the current snapshot without rebuilding the timeline.
    /// Use on lyric-line transitions: pre-generated future entries already
    /// drive the line change in the widget process, so a reload would only
    /// add WidgetKit scheduling latency. We still refresh the dataStore so
    /// on-demand reads (placeholder, configuration UI) stay accurate.
    func updateWidgetSnapshot() {
        guard #available(macOS 14, *) else { return }
        writeWidgetSnapshot(playbackState: nil, reloadOnSuccess: false)
    }

    private func writeWidgetSnapshot(playbackState explicitPlaybackState: PlaybackState?, reloadOnSuccess: Bool) {
        // let usedExplicit = explicitPlaybackState != nil
        guard let track = selectedPlayer.currentTrack else {
            // #log(.info, "[LXWG][Write] no current track → clearing dataStore + reloading timelines (reloadOnSuccess=\(reloadOnSuccess, privacy: .public), usedExplicit=\(usedExplicit, privacy: .public))")
            widgetDataStore.clear()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }

        let playbackState = explicitPlaybackState ?? selectedPlayer.playbackState
        let playbackTime = playbackState.time
        // #log(.info, "[LXWG][Write] enter (track=\(track.title ?? "nil", privacy: .public), isPlaying=\(playbackState.isPlaying, privacy: .public), time=\(playbackTime, privacy: .public), usedExplicit=\(usedExplicit, privacy: .public), reloadOnSuccess=\(reloadOnSuccess, privacy: .public))")

        // Build lyrics lines with context window
        var lyricsLines: [LyricsLineEntry] = []
        var widgetCurrentLineIndex = 0
        var availableTranslationLanguages: [String] = []

        if let lyrics = currentLyrics {
            availableTranslationLanguages = lyrics.metadata.translationLanguages
            let enabledLines = lyrics.lines.enumerated().filter { $0.element.enabled }
            let contextRadius = 50
            let (currentIndex, _) = lyrics[playbackTime + lyrics.adjustedTimeDelay]

            // Find the position of currentIndex in enabledLines
            let enabledCurrentPosition = enabledLines.firstIndex { $0.offset == currentIndex } ?? 0

            let startPosition = max(0, enabledCurrentPosition - contextRadius)
            let endPosition = min(enabledLines.count - 1, enabledCurrentPosition + contextRadius)

            if startPosition <= endPosition {
                let windowSlice = enabledLines[startPosition ... endPosition]
                lyricsLines = windowSlice.enumerated().map { windowIndex, indexedLine in
                    let line = indexedLine.element
                    let nextPosition = line.position // startTime
                    // Calculate endTime from the next enabled line
                    let sliceArray = Array(windowSlice)
                    let endTime: TimeInterval? = (windowIndex + 1 < sliceArray.count)
                        ? sliceArray[windowIndex + 1].element.position
                        : nil

                    // Collect translations for all available languages
                    let firstTranslationLanguage = availableTranslationLanguages.first
                    let translation = firstTranslationLanguage.flatMap {
                        line.attachments[.translation(languageCode: $0)]
                    }

                    return LyricsLineEntry(
                        text: line.content,
                        translation: translation,
                        startTime: nextPosition,
                        endTime: endTime
                    )
                }
                widgetCurrentLineIndex = enabledCurrentPosition - startPosition
            }
        }

        // Extract artwork color and cover data
        var backgroundColor: CodableColor?
        if let artwork = track.resolvedArtwork {
            backgroundColor = AlbumColorExtractor.dominantColor(from: artwork)
            if let coverData = AlbumColorExtractor.compressedCoverData(from: artwork) {
                try? widgetDataStore.writeCover(coverData)
            }
        } else {
            widgetDataStore.clearCover()
        }

        // Align widget's time axis with the main app's lyrics time axis.
        // The main app uses `playbackTime + adjustedTimeDelay` everywhere
        // (currentLineIndex computation, karaoke progress, HUD), where
        // adjustedTimeDelay folds in the lyrics file's [offset:] tag plus
        // the user's global offset preference. The widget's
        // LyricsLineEntry.startTime is the raw LRC position, so we have to
        // offset playbackPosition the same way — otherwise the widget
        // permanently lags the main app by adjustedTimeDelay seconds (up
        // to ~1s for files that ship a non-zero offset tag).
        let lyricsTimeDelay = currentLyrics?.adjustedTimeDelay ?? 0
        let widgetData = LyricsWidgetData(
            trackTitle: track.title ?? "Unknown",
            artist: track.artist ?? "Unknown",
            albumName: track.album,
            backgroundColor: backgroundColor,
            lyricsLines: lyricsLines,
            currentLineIndex: widgetCurrentLineIndex,
            isPlaying: playbackState.isPlaying,
            timestamp: Date(),
            playbackPosition: playbackTime + lyricsTimeDelay,
            availableTranslationLanguages: availableTranslationLanguages
        )

        do {
            try widgetDataStore.write(widgetData)
            // #log(.info, "[LXWG][Write] wrote snapshot (isPlaying=\(widgetData.isPlaying, privacy: .public), playbackPosition=\(widgetData.playbackPosition, privacy: .public), lineIndex=\(widgetData.currentLineIndex, privacy: .public), lyricsLines=\(widgetData.lyricsLines.count, privacy: .public), reloadOnSuccess=\(reloadOnSuccess, privacy: .public))")
        } catch {
            // #log(.error, "[LXWG][Write] dataStore.write failed: \(error.localizedDescription, privacy: .public)")
        }
        if reloadOnSuccess {
            // #log(.info, "[LXWG][Write] reloadAllTimelines()")
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

extension AppController {
    func refreshLocalLyricsChoices(completion: @escaping (MusicTrack?, [LocalLyricsChoice], Bool) -> Void) {
        guard let track = selectedPlayer.currentTrack else {
            DispatchQueue.main.async {
                completion(nil, [], true)
            }
            return
        }

        localLyricsRefreshQueue.async {
            // Return the adjacent files before asking the music player for its
            // embedded lyrics. That scripting-bridge property can block while
            // the player responds, even though the two local file checks are
            // just deterministic `fileExists` calls.
            let started = ProcessInfo.processInfo.systemUptime
            let adjacentChoices = self.localLyricsChoices(for: track, includeEmbedded: false)
            DispatchQueue.main.async {
                #if DEBUG
                NSLog("Local lyrics: first file results delivered after %.3fs", ProcessInfo.processInfo.systemUptime - started)
                #endif
                completion(track, adjacentChoices, false)
            }

            // Resolve a missing location before requesting embedded text.
            var resolvedTrack = track
            if resolvedTrack.fileURL == nil {
                resolvedTrack.fileURL = track.localFileURL
                let files = self.localLyricsChoices(for: resolvedTrack, includeEmbedded: false)
                DispatchQueue.main.async { completion(track, files, false) }
            }
            let metadataStarted = ProcessInfo.processInfo.systemUptime
            let choices = self.localLyricsChoices(for: resolvedTrack, includeEmbedded: true)
            #if DEBUG
            NSLog("Local lyrics: embedded stage took %.3fs", ProcessInfo.processInfo.systemUptime - metadataStarted)
            #endif
            DispatchQueue.main.async {
                completion(track, choices, true)
            }
        }
    }

    func applyLocalLyrics(_ choice: LocalLyricsChoice, completion: @escaping (Bool, Error?) -> Void) {
        let selectionID = withLyricsSelectionLock { () -> UUID? in
            guard selectedPlayer.currentTrack?.id == choice.track.id else {
                return nil
            }
            candidateReplenishID = UUID()
            candidateReplenishTask?.cancel()
            candidateReplenishTask = nil
            searchTask?.cancel()
            searchTask = nil
            searchRequest = nil
            let selectionID = UUID()
            localLyricsSelectionID = selectionID
            return selectionID
        }
        guard let selectionID else {
            DispatchQueue.main.async { completion(false, nil) }
            return
        }

        DispatchQueue.lyricsDisplay.async {
            let canStart = self.withLyricsSelectionLock { () -> Bool in
                guard self.localLyricsSelectionID == selectionID,
                      let track = selectedPlayer.currentTrack, track.id == choice.track.id else {
                    return false
                }
                // Track-change handling uses this same serial queue, so it cannot
                // replace searchTask between this check and cancellation.
                self.searchTask?.cancel()
                self.searchTask = nil
                self.searchRequest = nil
                return true
            }
            guard canStart else {
                DispatchQueue.main.async { completion(false, nil) }
                return
            }
            self.loadLocalLyrics(choice, selectionID: selectionID, completion: completion)
        }
    }

    private func loadLocalLyrics(
        _ choice: LocalLyricsChoice, selectionID: UUID, completion: @escaping (Bool, Error?) -> Void
    ) {
        localLyricsIOQueue.async {
            do {
                let lyrics: Lyrics
                var securityScopedDirectoryURL: URL?
                switch choice.source {
                case .embedded:
                    guard let parsedLyrics = Lyrics(choice.embeddedContents ?? "") else {
                        throw NSError(domain: lyricsXErrorDomain, code: 0, userInfo: [
                            NSLocalizedDescriptionKey: NSLocalizedString("Invalid lyric file", comment: "Lyrics parsing error"),
                        ])
                    }
                    lyrics = parsedLyrics
                case .file(let url):
                    securityScopedDirectoryURL = defaults.lyricsSecurityScopedDirectory(containing: url)
                    if let securityScopedDirectoryURL {
                        guard securityScopedDirectoryURL.startAccessingSecurityScopedResource() else {
                            throw CocoaError(.fileReadNoPermission)
                        }
                    }
                    let lyricsContents = try String(contentsOf: url, encoding: .utf8)
                    guard let parsedLyrics = Lyrics(lyricsContents) else {
                        throw NSError(domain: lyricsXErrorDomain, code: 0, userInfo: [
                            NSLocalizedDescriptionKey: NSLocalizedString("Invalid lyric file", comment: "Lyrics parsing error"),
                        ])
                    }
                    lyrics = parsedLyrics
                case .lyricsX:
                    if let memoryLyrics = choice.memoryLyrics {
                        lyrics = memoryLyrics
                    } else {
                        let fileCandidates = lyricsXFileCandidates(
                            for: choice.track,
                            preferredURL: choice.lyricsXFileURL
                        )
                        guard let managedLyrics = fileCandidates.lazy.compactMap({ candidateFile in
                            loadLyrics(
                                at: candidateFile.fileURL,
                                securityScopedURL: candidateFile.isSecurityScoped ? candidateFile.fileURL : nil,
                                title: choice.track.title ?? "",
                                artist: choice.track.artist ?? ""
                            )
                        }).first else {
                            throw NSError(domain: lyricsXErrorDomain, code: 0, userInfo: [
                                NSLocalizedDescriptionKey: NSLocalizedString("Invalid lyric file", comment: "Lyrics parsing error"),
                            ])
                        }
                        lyrics = managedLyrics
                    }
                }
                defer {
                    securityScopedDirectoryURL?.stopAccessingSecurityScopedResource()
                }
                lyrics.associateWithTrack(choice.track)
                if case .file(let url) = choice.source {
                    lyrics.metadata.localURL = url
                }
                lyrics.filtrate()
                lyrics.recognizeLanguage()

                DispatchQueue.lyricsDisplay.async {
                    let didCommit = self.withLyricsSelectionLock { () -> Bool in
                        guard self.localLyricsSelectionID == selectionID,
                              let track = selectedPlayer.currentTrack, track.id == choice.track.id else {
                            return false
                        }
                        self.searchTask?.cancel()
                        self.searchTask = nil
                        self.searchRequest = nil
                        self.currentLyrics = lyrics
                        self.currentLocalLyricsSource = choice.source
                        return true
                    }
                    guard didCommit else {
                        DispatchQueue.main.async {
                            completion(false, nil)
                        }
                        return
                    }
                    DispatchQueue.main.async {
                        completion(true, nil)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    let isCurrent = self.withLyricsSelectionLock {
                        self.localLyricsSelectionID == selectionID
                    }
                    completion(false, isCurrent ? error : nil)
                }
            }
        }
    }

    private func localLyricsChoices(
        for track: MusicTrack,
        includeEmbedded: Bool
    ) -> [LocalLyricsChoice] {
        var choices: [LocalLyricsChoice] = []
        if includeEmbedded,
           let embedded = track.lyrics,
           !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            choices.append(LocalLyricsChoice(
                track: track, source: .embedded,
                title: NSLocalizedString("Embedded Lyrics", comment: "Local lyrics menu option"),
                embeddedContents: embedded
            ))
        }
        if let musicFileURL = track.fileURL {
            // The supported names are deterministic: only the two files beside
            // the music file can match. Avoid enumerating the whole directory,
            // which can block for many seconds on large or cloud-backed folders.
            let lyricsFiles = ["lrc", "lrcx"].compactMap { extensionName -> URL? in
                let url = musicFileURL.deletingPathExtension().appendingPathExtension(extensionName)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return nil
                }
                return url
            }
            choices += lyricsFiles.map { LocalLyricsChoice(track: track, source: .file($0), title: $0.lastPathComponent) }
        }
        // Keep only the one online result selected for display. Other automatic
        // search arrivals remain in the candidate pool and are not menu items.
        if let lyrics = selectedOnlineLyrics(for: track.id) {
            choices.append(LocalLyricsChoice(
                track: track,
                source: .lyricsX,
                title: "LyricsX",
                memoryLyrics: lyrics
            ))
        } else {
            // An online candidate replaces the LyricsX-library entry for this
            // track. Once the track changes, the selected in-memory entry is
            // cleared and the library file is discovered again.
            let libraryChoices = libraryLyricsChoices(for: track)
            choices += libraryChoices.filter { libraryChoice in
                !choices.contains { $0.source == libraryChoice.source }
            }
        }
        return choices
    }

    private func libraryLyricsChoices(for track: MusicTrack) -> [LocalLyricsChoice] {
        let title = track.title ?? ""
        let artist = track.artist ?? ""
        let (directoryURL, isSecurityScoped) = defaults.lyricsSavingPath()
        if isSecurityScoped {
            guard directoryURL.startAccessingSecurityScopedResource() else {
                return []
            }
            defer {
                directoryURL.stopAccessingSecurityScopedResource()
            }
        }
        guard let candidateFile = librarySearchFiles(title: title, artist: artist).first(where: {
            FileManager.default.fileExists(atPath: $0.fileURL.path)
        }) else {
            return []
        }
        return [LocalLyricsChoice(
            track: track,
            source: .lyricsX,
            title: "LyricsX",
            lyricsXFileURL: candidateFile.fileURL
        )]
    }

    private func persistCurrentLyrics() {
        let lyrics = withLyricsSelectionLock { currentLyrics }
        guard let lyrics, lyrics.metadata.needsPersist else { return }
        lyrics.persist()
    }

    func importLyrics(_ lyricsString: String, filePath: String? = nil) throws {
        // Pick the parser by file extension first (drag-and-drop of a `.ttml`
        // file). For pasted text without a path, auto-detect by root element.
        let isTTML: Bool = {
            if let filePath {
                return (filePath as NSString).pathExtension.lowercased() == "ttml"
            }
            return lyricsString.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<tt")
        }()
        let parsed: Lyrics? = isTTML ? Lyrics(ttmlContent: lyricsString) : Lyrics(lyricsString)
        guard let lrc = parsed else {
            let errorInfo = [
                NSLocalizedDescriptionKey: "Invalid lyric file",
                NSLocalizedRecoverySuggestionErrorKey: "Please try another one.",
            ]
            let error = NSError(domain: lyricsXErrorDomain, code: 0, userInfo: errorInfo)
            throw error
        }
        guard let track = selectedPlayer.currentTrack else {
            let errorInfo = [
                NSLocalizedDescriptionKey: "No music playing",
                NSLocalizedRecoverySuggestionErrorKey: "Play a music and try again.",
            ]
            let error = NSError(domain: lyricsXErrorDomain, code: 0, userInfo: errorInfo)
            throw error
        }
        lrc.metadata.title = track.title
        lrc.metadata.artist = track.artist
        lrc.applyQQMusicKanaFurigana()
        lrc.filtrate()
        lrc.recognizeLanguage()
        lrc.markAsUserPicked(origin: .import)
        lrc.metadata.needsPersist = true
        currentLyrics = lrc
        // An imported file is as deliberate a choice as picking a candidate, so
        // it takes over the pool and is pinned against a search still in flight.
        adoptLyricsCandidates([lrc], selecting: lrc, for: track)
        if let index = defaults[.noSearchingTrackIds].firstIndex(of: track.id) {
            defaults[.noSearchingTrackIds].remove(at: index)
        }
        if let index = defaults[.noSearchingAlbumNames].firstIndex(of: track.album ?? "") {
            defaults[.noSearchingAlbumNames].remove(at: index)
        }
    }
}
