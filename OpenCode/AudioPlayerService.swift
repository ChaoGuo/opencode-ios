import Foundation
import AVFoundation

#if os(iOS)
@Observable
final class AudioPlayerService: NSObject {
    static let shared = AudioPlayerService()

    var playingFilename: String?
    var isPlaying = false

    // Cache: filename -> audio data (for local playback)
    private var cache: [String: Data] = [:]
    private var player: AVAudioPlayer?

    private override init() {}

    func cacheAudio(data: Data, filename: String) {
        cache[filename] = data
    }

    func play(filename: String) {
        // If already playing this file, stop
        if playingFilename == filename && isPlaying {
            stop()
            return
        }

        guard let data = cache[filename] else { return }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            player?.play()
            playingFilename = filename
            isPlaying = true
        } catch {
            print("AudioPlayer error: \(error)")
        }
    }

    // Play from a data URL string (data:audio/m4a;base64,...)
    func play(dataURL: String, filename: String) {
        if cache[filename] != nil {
            play(filename: filename)
            return
        }
        guard dataURL.hasPrefix("data:"),
              let commaIdx = dataURL.firstIndex(of: ",") else { return }
        let base64 = String(dataURL[dataURL.index(after: commaIdx)...])
        guard let data = Data(base64Encoded: base64) else { return }
        cache[filename] = data
        play(filename: filename)
    }

    /// Play from an HTTP URL. If cache miss, downloads first (using file service auth) then plays.
    func play(url urlString: String, filename: String) {
        if cache[filename] != nil {
            play(filename: filename)
            return
        }
        if let cached = APIService.cachedFileData(for: urlString) {
            cache[filename] = cached
            play(filename: filename)
            return
        }
        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url)
        if let auth = AppSettings.shared.fileServiceAuthHeader {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                APIService.cacheFile(data, urlString: urlString)
                await MainActor.run {
                    self.cache[filename] = data
                    self.play(filename: filename)
                }
            } catch {
                print("[AudioPlayer] download failed: \(error)")
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        playingFilename = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func hasCached(_ filename: String) -> Bool {
        cache[filename] != nil
    }
}

extension AudioPlayerService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        playingFilename = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
