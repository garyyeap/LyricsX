import AppKit
import Combine
import Regex
import OpenCC
import MusicPlayer
import LyricsXFoundation

class AppController: NSObject {
    static let shared = AppController()

    enum LocalLyricsSource: Equatable {
        case embedded
        case file(URL)
    }

    struct LocalLyricsChoice {
        let track: MusicTrack
        let source: LocalLyricsSource
        let title: String
    }

    private(set) var currentLocalLyricsSource: LocalLyricsSource?

    var lyricsManager: LyricsProvider
    private let localLyricsIOQueue = DispatchQueue(label: "LocalLyricsIO", qos: .userInitiated)
    // Lyrics can also be replaced by main-thread menu/search actions. Protect
    // invalidation and the final local-load commit as one operation.
    private let localLyricsSelectionLock = NSRecursiveLock()
    private var localLyricsSelectionID = UUID()

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

    private var cancelBag = Set<AnyCancellable>()

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
        selectedPlayer.currentTrackWillChange
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .invoke(AppController.currentTrackChanged, weaklyOn: self)
            .store(in: &cancelBag)
        selectedPlayer.playbackStateWillChange
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .invoke(AppController.scheduleCurrentLineCheck, weaklyOn: self)
            .store(in: &cancelBag)

        workspaceNC.publisher(for: NSWorkspace.didTerminateApplicationNotification, object: nil)
            .sink { notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let bundleID = application.bundleIdentifier
                if defaults[.launchAndQuitWithPlayer], (selectedPlayer.designatedPlayer as? MusicPlayers.Scriptable)?.playerBundleID == bundleID {
                    NSApplication.shared.terminate(self)
                }
            }.store(in: &cancelBag)
        currentTrackChanged()

        Task {
            try await updateLyricsManager()
        }
    }

    @MainActor
    func updateLyricsManager() async throws {
        let services: [LyricsProviders.Service] = LyricsProviders.Service.noAuthenticationRequiredServices

        var providers: [LyricsProvider] = []
        for service in services {
            providers.append(service.create())
        }

        // Add Musixmatch provider with saved token if available
        if let token = defaults[.musixmatchToken], !token.isEmpty {
            let musixmatchProvider = LyricsProviders.Musixmatch(usertoken: token)
            providers.append(musixmatchProvider)
        }

        lyricsManager = LyricsProviders.Group(providers: providers)
    }

    var currentLineCheckSchedule: Cancellable?

    func scheduleCurrentLineCheck() {
        currentLineCheckSchedule?.cancel()
        guard let lyrics = currentLyrics else {
            return
        }
        let playbackState = MusicPlayers.Selected.shared.playbackState
        let playbackTime = playbackState.time
        let (index, next) = lyrics[playbackTime + lyrics.adjustedTimeDelay]
        if currentLineIndex != index {
            currentLineIndex = index
        }
        if let next = next, playbackState.isPlaying {
            let dt = lyrics.lines[next].position - playbackTime - lyrics.adjustedTimeDelay
            let q = DispatchQueue.lyricsDisplay
            currentLineCheckSchedule = q.schedule(after: q.now.advanced(by: .seconds(dt)), interval: .seconds(42), tolerance: .milliseconds(20)) { [unowned self] in
                self.scheduleCurrentLineCheck()
            }
        }
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
        currentLyrics = nil
        currentLineIndex = nil
        searchTask?.cancel()
        searchRequest = nil
        guard let track = selectedPlayer.currentTrack else {
            return
        }
        // FIXME: deal with optional value
        let title = track.title ?? ""
        let artist = track.artist ?? ""

        guard !defaults[.noSearchingTrackIds].contains(track.id) else {
            return
        }

        var candidateLyricsURL: [(URL, Bool, Bool)] = [] // (fileURL, isSecurityScoped, needsSearching)

        if defaults[.loadLyricsBesideTrack] {
            if let embeddedLyrics = track.lyrics, !embeddedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let lyrics = Lyrics(embeddedLyrics) {
                    if lyrics.metadata.title == nil || lyrics.metadata.title?.isEmpty == true {
                        lyrics.metadata.title = title
                    }
                    if lyrics.metadata.artist == nil || lyrics.metadata.artist?.isEmpty == true {
                        lyrics.metadata.artist = artist
                    }
                    lyrics.filtrate()
                    lyrics.recognizeLanguage()
                    currentLyrics = lyrics
                    currentLocalLyricsSource = .embedded
                    return
                }
            }
            if let fileName = track.localFileURL?.deletingPathExtension() {
                candidateLyricsURL += [
                    (fileName.appendingPathExtension("lrcx"), false, false),
                    (fileName.appendingPathExtension("lrc"), false, false),
                ]
            }
        }

        let (url, security) = defaults.lyricsSavingPath()
        let titleForReading = title.replacingOccurrences(of: "/", with: ":")
        let artistForReading = artist.replacingOccurrences(of: "/", with: ":")
        let fileName = url.appendingPathComponent("\(titleForReading) - \(artistForReading)")
        candidateLyricsURL += [
            (fileName.appendingPathExtension("lrcx"), security, false),
            (fileName.appendingPathExtension("lrc"), security, true),
        ]

        for (url, security, needsSearching) in candidateLyricsURL {
            if security {
                guard url.startAccessingSecurityScopedResource() else {
                    continue
                }
            }
            defer {
                if security {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            if let lrcContents = try? String(contentsOf: url, encoding: String.Encoding.utf8),
               let lyrics = Lyrics(lrcContents) {
                lyrics.metadata.localURL = url
                lyrics.metadata.title = title
                lyrics.metadata.artist = artist
                lyrics.filtrate()
                lyrics.recognizeLanguage()
                currentLyrics = lyrics
                currentLocalLyricsSource = .file(url)
                if needsSearching {
                    break
                } else {
                    return
                }
            }
        }

        if let album = track.album, defaults[.noSearchingAlbumNames].contains(album) {
            return
        }

        let duration = track.duration ?? 0
        let request = LyricsSearchRequest(searchTerm: .info(title: title, artist: artist), duration: duration, limit: 5)
        searchRequest = request
        searchTask = Task { @MainActor in
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
                        if let current = currentLyrics, current === lyrics {
                            firstReceived = true
                            collectionStart = Date()
                        }
                        continue
                    }

                    if let start = collectionStart,
                       Date().timeIntervalSince(start) <= window {
                        lyricsReceived(lyrics: lyrics)
                        continue
                    } else {
                        // window expired
                        break
                    }
                }

                try Task.checkCancellation()
                guard searchRequest == request else {
                    return
                }
                if defaults[.writeToiTunesAutomatically] {
                    writeToiTunes(overwrite: true)
                }
            } catch is CancellationError {
                // Search was cancelled due to track change
            } catch {
                print("Failed to fetch lyrics: \(error.localizedDescription)")
            }
        }
    }

    // MARK: LyricsSourceDelegate

    func lyricsReceived(lyrics: Lyrics) {
        guard let req = searchRequest,
              lyrics.metadata.request == req,
              let track = selectedPlayer.currentTrack else {
            return
        }
        if defaults[.strictSearchEnabled], !lyrics.isMatched() {
            return
        }
        if let current = currentLyrics, !lyricsHasHigherPriority(lyrics, over: current) {
            return
        }

        lyrics.associateWithTrack(track)
        lyrics.filtrate()
        lyrics.recognizeLanguage()
        lyrics.metadata.needsPersist = true
        currentLyrics = lyrics
    }
}

extension AppController {
    func refreshLocalLyricsChoices(completion: @escaping (MusicTrack?, [LocalLyricsChoice]) -> Void) {
        guard let track = selectedPlayer.currentTrack else {
            DispatchQueue.main.async {
                completion(nil, [])
            }
            return
        }

        localLyricsIOQueue.async {
            let choices = self.localLyricsChoices(for: track)
            DispatchQueue.main.async {
                completion(track, choices)
            }
        }
    }

    func applyLocalLyrics(_ choice: LocalLyricsChoice, completion: @escaping (Bool, Error?) -> Void) {
        localLyricsSelectionLock.lock()
        let selectionID = UUID()
        localLyricsSelectionID = selectionID
        localLyricsSelectionLock.unlock()

        DispatchQueue.lyricsDisplay.async {
            self.localLyricsSelectionLock.lock()
            defer { self.localLyricsSelectionLock.unlock() }
            guard self.localLyricsSelectionID == selectionID,
                  let track = selectedPlayer.currentTrack, track.id == choice.track.id else {
                DispatchQueue.main.async { completion(false, nil) }
                return
            }
            // Track-change handling uses this same serial queue, so it cannot
            // replace searchTask between this check and cancellation.
            self.searchTask?.cancel()
            self.searchRequest = nil
            self.loadLocalLyrics(choice, selectionID: selectionID, completion: completion)
        }
    }

    private func loadLocalLyrics(
        _ choice: LocalLyricsChoice, selectionID: UUID, completion: @escaping (Bool, Error?) -> Void
    ) {
        localLyricsIOQueue.async {
            do {
                let lyricsContents: String
                switch choice.source {
                case .embedded:
                    lyricsContents = choice.track.lyrics ?? ""
                case .file(let url):
                    lyricsContents = try String(contentsOf: url, encoding: .utf8)
                }
                guard let lyrics = Lyrics(lyricsContents) else {
                    throw NSError(domain: lyricsXErrorDomain, code: 0, userInfo: [
                        NSLocalizedDescriptionKey: NSLocalizedString("Invalid lyric file", comment: "Lyrics parsing error"),
                    ])
                }
                lyrics.associateWithTrack(choice.track)
                if case .file(let url) = choice.source {
                    lyrics.metadata.localURL = url
                }
                lyrics.filtrate()
                lyrics.recognizeLanguage()

                DispatchQueue.lyricsDisplay.async {
                    self.localLyricsSelectionLock.lock()
                    defer { self.localLyricsSelectionLock.unlock() }
                    guard self.localLyricsSelectionID == selectionID,
                          let track = selectedPlayer.currentTrack, track.id == choice.track.id else {
                        DispatchQueue.main.async {
                            completion(false, nil)
                        }
                        return
                    }
                    self.searchTask?.cancel()
                    self.searchRequest = nil
                    self.currentLyrics = lyrics
                    self.currentLocalLyricsSource = choice.source
                    DispatchQueue.main.async {
                        completion(true, nil)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.localLyricsSelectionLock.lock()
                    let isCurrent = self.localLyricsSelectionID == selectionID
                    self.localLyricsSelectionLock.unlock()
                    completion(false, isCurrent ? error : nil)
                }
            }
        }
    }

    private func localLyricsChoices(for track: MusicTrack) -> [LocalLyricsChoice] {
        var choices: [LocalLyricsChoice] = []
        if let embedded = track.lyrics, !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            choices.append(LocalLyricsChoice(
                track: track, source: .embedded,
                title: NSLocalizedString("Embedded Lyrics", comment: "Local lyrics menu option")
            ))
        }
        if let directory = track.localFileURL?.deletingLastPathComponent(),
           let files = try? FileManager.default.contentsOfDirectory(
               at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
           ) {
            let lyricsFiles = files.filter {
                ["lrc", "lrcx"].contains($0.pathExtension.lowercased()) &&
                    (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            choices += lyricsFiles.map { LocalLyricsChoice(track: track, source: .file($0), title: $0.lastPathComponent) }
        }
        return choices
    }

    private func persistCurrentLyrics() {
        guard let lyrics = currentLyrics, lyrics.metadata.needsPersist else { return }
        lyrics.persist()
    }

    func importLyrics(_ lyricsString: String) throws {
        guard let lrc = Lyrics(lyricsString) else {
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
        lrc.filtrate()
        lrc.recognizeLanguage()
        lrc.metadata.needsPersist = true
        currentLyrics = lrc
        if let index = defaults[.noSearchingTrackIds].firstIndex(of: track.id) {
            defaults[.noSearchingTrackIds].remove(at: index)
        }
        if let index = defaults[.noSearchingAlbumNames].firstIndex(of: track.album ?? "") {
            defaults[.noSearchingAlbumNames].remove(at: index)
        }
    }
}
