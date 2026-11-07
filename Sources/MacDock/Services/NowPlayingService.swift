import AppKit
import Observation

/// What's playing system-wide (Spotify, Music, a browser video…), from the private
/// MediaRemote framework that powers the menu bar's Now Playing controls.
///
/// Since macOS 15.4, MediaRemote only answers Apple-signed processes, so the
/// queries run inside `osascript` (JavaScript for Automation), which is one. A single
/// long-lived helper polls once a second and prints a JSON line whenever something
/// changes; commands are one-shot helpers. If anything fails, `objTrack` stays `nil`
/// and the dock simply shows no Now Playing tile.
@MainActor
@Observable
final class NowPlayingService {
    /// The current track.
    struct Track: Equatable {
        let strTitle: String
        let strArtist: String
        let objArtwork: NSImage?
        /// App playing it (e.g. Spotify, Chrome), when known.
        let strBundleId: String?

        /// Equal when the same track from the same app is playing (artwork compared by presence).
        static func == (lhs: Track, rhs: Track) -> Bool {
            lhs.strTitle == rhs.strTitle && lhs.strArtist == rhs.strArtist
                && lhs.strBundleId == rhs.strBundleId && (lhs.objArtwork == nil) == (rhs.objArtwork == nil)
        }
    }

    /// Commands understood by `MRMediaRemoteSendCommand`.
    enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    /// Current track, or `nil` when nothing is playing (or MediaRemote is unavailable).
    private(set) var objTrack: Track?
    /// Whether it's playing (vs paused).
    private(set) var blnIsPlaying = false
    /// Track length in seconds (0 when unknown, e.g. live streams).
    private(set) var dblDuration: Double = 0
    /// Position in seconds as of `objPositionDate`.
    @ObservationIgnored private var dblElapsedAtStamp: Double = 0
    /// When `dblElapsedAtStamp` was measured.
    @ObservationIgnored private var objPositionDate = Date()

    /// Current position in seconds, extrapolated while playing.
    /// - Parameter objNow: Moment to evaluate at.
    /// - Returns: Seconds into the track (clamped to the duration when known).
    func elapsed(at objNow: Date = Date()) -> Double {
        let dblElapsed = dblElapsedAtStamp + (blnIsPlaying ? objNow.timeIntervalSince(objPositionDate) : 0)
        return dblDuration > 0 ? min(max(0, dblElapsed), dblDuration) : max(0, dblElapsed)
    }

    /// Called when the track or play state changes.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var objHelper: Process?
    @ObservationIgnored private var strLineBuffer = ""
    /// Artwork of the current track (sent only when the track changes).
    @ObservationIgnored private var objLastArtwork: NSImage?
    /// Restarts after the helper dies unexpectedly, capped so a broken system doesn't spin.
    @ObservationIgnored private var intRestarts = 0
    /// Track whose Spotify artwork was last requested (so each track is fetched once).
    @ObservationIgnored private var strArtworkFetchKey: String?

    /// Shared prelude: loads MediaRemote inside the helper.
    private static let strPrelude = """
    ObjC.import('Foundation');
    $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
    """

    /// Poll loop: prints `{"title","artist","bundle","playing","art"}` on every change
    /// (`art` is base64 artwork, included only when the track changes).
    private static let strWatchScript = strPrelude + """
    const MR = $.NSClassFromString('MRNowPlayingRequest');
    const out = $.NSFileHandle.fileHandleWithStandardOutput;
    function emit(o) { out.writeData($(JSON.stringify(o) + '\\n').dataUsingEncoding($.NSUTF8StringEncoding)); }
    function str(v) { const s = ObjC.unwrap(v); return typeof s === 'string' ? s : ''; }
    function num(v) { const n = ObjC.unwrap(v); return typeof n === 'number' ? n : 0; }
    let strLast = '', strLastTrack = '';
    while (true) {
      let o = { title: '', artist: '', bundle: '', playing: false, elapsed: 0, duration: 0, rate: 0, ts: 0 };
      try {
        const objInfo = MR.localNowPlayingItem.nowPlayingInfo;
        if (!objInfo.isNil()) {
          o.title = str(objInfo.valueForKey('kMRMediaRemoteNowPlayingInfoTitle'));
          o.artist = str(objInfo.valueForKey('kMRMediaRemoteNowPlayingInfoArtist'));
          // Position as of `ts` (seconds since 1970); it advances at `rate` from there.
          o.elapsed = num(objInfo.valueForKey('kMRMediaRemoteNowPlayingInfoElapsedTime'));
          o.duration = num(objInfo.valueForKey('kMRMediaRemoteNowPlayingInfoDuration'));
          o.rate = num(objInfo.valueForKey('kMRMediaRemoteNowPlayingInfoPlaybackRate'));
          const objStamp = objInfo.valueForKey('kMRMediaRemoteNowPlayingInfoTimestamp');
          if (!objStamp.isNil()) { o.ts = objStamp.timeIntervalSince1970; }
        }
        o.playing = !!MR.localIsPlaying;
        const objPath = MR.localNowPlayingPlayerPath;
        if (!objPath.isNil()) { o.bundle = str(objPath.client.bundleIdentifier); }
      } catch (e) {}
      const strKey = JSON.stringify(o);
      if (strKey !== strLast) {
        const strTrack = o.title + '|' + o.artist + '|' + o.bundle;
        if (strTrack !== strLastTrack && o.title) {
          try {
            const objArt = MR.localNowPlayingItem.nowPlayingInfo.valueForKey('kMRMediaRemoteNowPlayingInfoArtworkData');
            if (!objArt.isNil()) { o.art = ObjC.unwrap(objArt.base64EncodedStringWithOptions(0)); }
          } catch (e) {}
          strLastTrack = strTrack;
        }
        emit(o);
        strLast = strKey;
      }
      delay(1);
    }
    """

    /// Starts the watcher.
    func start() {
        guard objHelper == nil else { return }
        let objProcess = Process()
        objProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        objProcess.arguments = ["-l", "JavaScript", "-e", Self.strWatchScript]
        let objPipe = Pipe()
        objProcess.standardOutput = objPipe
        objProcess.standardError = FileHandle.nullDevice

        // Lines arrive on a background queue; parse them on the main actor.
        objPipe.fileHandleForReading.readabilityHandler = { [weak self] objHandle in
            let objData = objHandle.availableData
            guard !objData.isEmpty, let strChunk = String(data: objData, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.consume(strChunk)
            }
        }
        // Restart a crashed helper a few times (never after `stop()`).
        objProcess.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.objHelper === objProcess else { return }
                self.objHelper = nil
                guard self.intRestarts < 5 else { return }
                self.intRestarts += 1
                try? await Task.sleep(for: .seconds(2))
                self.start()
            }
        }
        do {
            try objProcess.run()
            objHelper = objProcess
        } catch {
            NSLog("MacDock: couldn't start Now Playing helper: \(error)")
        }
    }

    /// Stops the watcher.
    func stop() {
        let objProcess = objHelper
        objHelper = nil
        objProcess?.terminate()
    }

    /// Sends a playback command to whatever is playing.
    /// - Parameter enmCommand: Command.
    func send(_ enmCommand: Command) {
        runCommand("""
        ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
        $.MRMediaRemoteSendCommand(\(enmCommand.rawValue), $());
        """)
        // Show the expected play state right away; the watcher confirms within a second.
        switch enmCommand {
        case .play: setPlaying(true)
        case .pause: setPlaying(false)
        case .togglePlayPause: setPlaying(!blnIsPlaying)
        case .nextTrack, .previousTrack: break
        }
    }

    /// Jumps to a position in the current track.
    /// - Parameter dblSeconds: Target position.
    func seek(to dblSeconds: Double) {
        let dblTarget = dblDuration > 0 ? min(max(0, dblSeconds), dblDuration) : max(0, dblSeconds)
        runCommand("""
        ObjC.bindFunction('MRMediaRemoteSetElapsedTime', ['void', ['double']]);
        $.MRMediaRemoteSetElapsedTime(\(dblTarget));
        """)
        // Move the bar right away; the watcher confirms within a second.
        dblElapsedAtStamp = dblTarget
        objPositionDate = Date()
        onChange?()
    }

    /// Runs a one-shot MediaRemote snippet in an `osascript` helper.
    ///
    /// Commands are delivered asynchronously, so the helper waits briefly before
    /// exiting; quitting right away drops them silently (while still reporting success).
    /// - Parameter strBody: JavaScript to run after MediaRemote is loaded.
    private func runCommand(_ strBody: String) {
        let objProcess = Process()
        objProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        objProcess.arguments = ["-l", "JavaScript", "-e", Self.strPrelude + strBody + "\ndelay(0.5);"]
        objProcess.standardOutput = FileHandle.nullDevice
        objProcess.standardError = FileHandle.nullDevice
        try? objProcess.run()
    }

    // MARK: - Parsing

    /// Splits helper output into lines and applies each complete one.
    /// - Parameter strChunk: Newly read text.
    private func consume(_ strChunk: String) {
        strLineBuffer += strChunk
        while let objRange = strLineBuffer.range(of: "\n") {
            let strLine = String(strLineBuffer[..<objRange.lowerBound])
            strLineBuffer.removeSubrange(..<objRange.upperBound)
            apply(strLine)
        }
    }

    /// Applies one JSON status line from the helper.
    /// - Parameter strLine: Line.
    private func apply(_ strLine: String) {
        guard let objData = strLine.data(using: .utf8),
              let dictStatus = try? JSONSerialization.jsonObject(with: objData) as? [String: Any] else { return }
        intRestarts = 0
        let strTitle = dictStatus["title"] as? String ?? ""
        let strArtist = dictStatus["artist"] as? String ?? ""
        let strBundleId = (dictStatus["bundle"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // Artwork only comes with a track change; keep it for later lines of the same track.
        let blnSameTrack = objTrack?.strTitle == strTitle && objTrack?.strArtist == strArtist
            && objTrack?.strBundleId == strBundleId
        if let strArt = dictStatus["art"] as? String, let objArtData = Data(base64Encoded: strArt) {
            objLastArtwork = NSImage(data: objArtData)
        } else if !blnSameTrack {
            objLastArtwork = nil
        }

        let objNew = strTitle.isEmpty ? nil
            : Track(strTitle: strTitle, strArtist: strArtist, objArtwork: objLastArtwork, strBundleId: strBundleId)
        let blnPlaying = dictStatus["playing"] as? Bool ?? false

        // Position: MediaRemote reports where the track was at a timestamp.
        let dblStamp = dictStatus["ts"] as? Double ?? 0
        dblElapsedAtStamp = dictStatus["elapsed"] as? Double ?? 0
        objPositionDate = dblStamp > 0 ? Date(timeIntervalSince1970: dblStamp) : Date()
        let dblNewDuration = dictStatus["duration"] as? Double ?? 0

        // Spotify doesn't share artwork with MediaRemote; ask Spotify for it instead.
        if let objNew, objNew.objArtwork == nil, strBundleId == Self.strSpotifyId {
            fetchSpotifyArtwork(strTrackKey: Self.trackKey(objNew))
        }

        guard objNew != objTrack || blnPlaying != blnIsPlaying || dblNewDuration != dblDuration else { return }
        objTrack = objNew
        blnIsPlaying = blnPlaying
        dblDuration = dblNewDuration
        onChange?()
    }

    // MARK: - Spotify artwork

    private static let strSpotifyId = "com.spotify.client"

    /// Identity of a track for matching late artwork to it.
    /// - Parameter objTrack: Track.
    /// - Returns: Key.
    private static func trackKey(_ objTrack: Track) -> String {
        "\(objTrack.strBundleId ?? "")|\(objTrack.strTitle)|\(objTrack.strArtist)"
    }

    /// Fetches the current Spotify track's cover (once per track) and attaches it if
    /// that track is still playing when it arrives.
    ///
    /// Spotify's AppleScript gives the cover's URL. The first time, macOS asks whether
    /// MacDock may control Spotify; if that's declined, the tile keeps the Spotify icon.
    /// - Parameter strTrackKey: Track the artwork is for.
    private func fetchSpotifyArtwork(strTrackKey: String) {
        guard strArtworkFetchKey != strTrackKey else { return }
        strArtworkFetchKey = strTrackKey

        let objProcess = Process()
        objProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        objProcess.arguments = ["-e", "tell application id \"\(Self.strSpotifyId)\" to get artwork url of current track"]
        let objPipe = Pipe()
        objProcess.standardOutput = objPipe
        objProcess.standardError = FileHandle.nullDevice
        objProcess.terminationHandler = { [weak self] _ in
            let objOutput = objPipe.fileHandleForReading.readDataToEndOfFile()
            let strUrl = String(data: objOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let objUrl = URL(string: strUrl), objUrl.scheme == "https" else { return }
            Task { [weak self] in
                guard let (objData, _) = try? await URLSession.shared.data(from: objUrl),
                      let objImage = NSImage(data: objData) else { return }
                await self?.attachArtwork(objImage, strTrackKey: strTrackKey)
            }
        }
        try? objProcess.run()
    }

    /// Sets late-arriving artwork on the current track, if it's still the same one.
    /// - Parameters:
    ///   - objImage: Cover art.
    ///   - strTrackKey: Track it belongs to.
    private func attachArtwork(_ objImage: NSImage, strTrackKey: String) {
        guard let objCurrent = objTrack, Self.trackKey(objCurrent) == strTrackKey else { return }
        objLastArtwork = objImage
        objTrack = Track(strTitle: objCurrent.strTitle, strArtist: objCurrent.strArtist,
                         objArtwork: objImage, strBundleId: objCurrent.strBundleId)
        onChange?()
    }

    /// Updates the play state optimistically.
    /// - Parameter blnPlaying: New state.
    private func setPlaying(_ blnPlaying: Bool) {
        guard blnIsPlaying != blnPlaying else { return }
        blnIsPlaying = blnPlaying
        onChange?()
    }
}
