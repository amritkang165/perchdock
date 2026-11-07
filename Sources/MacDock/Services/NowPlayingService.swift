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

    /// Called when the track or play state changes.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var objHelper: Process?
    @ObservationIgnored private var strLineBuffer = ""
    /// Artwork of the current track (sent only when the track changes).
    @ObservationIgnored private var objLastArtwork: NSImage?
    /// Restarts after the helper dies unexpectedly, capped so a broken system doesn't spin.
    @ObservationIgnored private var intRestarts = 0

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
    let strLast = '', strLastTrack = '';
    while (true) {
      let o = { title: '', artist: '', bundle: '', playing: false };
      try {
        const objInfo = MR.localNowPlayingItem.nowPlayingInfo;
        if (!objInfo.isNil()) {
          o.title = str(objInfo.valueForKey('kMRMediaRemoteNowPlayingInfoTitle'));
          o.artist = str(objInfo.valueForKey('kMRMediaRemoteNowPlayingInfoArtist'));
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
        let strScript = Self.strPrelude + """
        ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
        $.MRMediaRemoteSendCommand(\(enmCommand.rawValue), $());
        """
        let objProcess = Process()
        objProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        objProcess.arguments = ["-l", "JavaScript", "-e", strScript]
        objProcess.standardOutput = FileHandle.nullDevice
        objProcess.standardError = FileHandle.nullDevice
        try? objProcess.run()
        // Show the expected play state right away; the watcher confirms within a second.
        switch enmCommand {
        case .play: setPlaying(true)
        case .pause: setPlaying(false)
        case .togglePlayPause: setPlaying(!blnIsPlaying)
        case .nextTrack, .previousTrack: break
        }
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
        guard objNew != objTrack || blnPlaying != blnIsPlaying else { return }
        objTrack = objNew
        blnIsPlaying = blnPlaying
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
