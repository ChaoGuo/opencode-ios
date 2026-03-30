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
        if let cached = cache[filename] {
            _ = cached  // already cached, use play(filename:)
            play(filename: filename)
            return
        }
        // Decode data URL
        guard dataURL.hasPrefix("data:"),
              let commaIdx = dataURL.firstIndex(of: ",") else { return }
        let base64 = String(dataURL[dataURL.index(after: commaIdx)...])
        guard let data = Data(base64Encoded: base64) else { return }
        cache[filename] = data
        play(filename: filename)
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
