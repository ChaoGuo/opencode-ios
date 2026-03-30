import Foundation
import AVFoundation

#if os(iOS)
@Observable
final class VoiceRecorderService {
    static let shared = VoiceRecorderService()

    var isRecording = false
    var permissionDenied = false
    var recordingDuration: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingStartTime: Date?

    private init() {}

    // Returns true if recording started successfully
    func startRecording() async -> Bool {
        let session = AVAudioSession.sharedInstance()

        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            permissionDenied = true
            return false
        }

        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            return false
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice_\(Int(Date().timeIntervalSince1970)).m4a")
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.record()
            recordingStartTime = Date()
            isRecording = true
            return true
        } catch {
            return false
        }
    }

    // Returns the recorded file URL, nil if cancelled
    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil
        isRecording = false
        recordingDuration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartTime = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return recordingURL
    }

    func cancelRecording() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
