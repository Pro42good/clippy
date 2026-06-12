import AVFoundation
import Foundation
import ScreenCaptureKit
import Speech

@MainActor
enum RecorderDiagnostics {
    static func snapshot(recorder: ScreenRecorder) -> String {
        var lines: [String] = []
        lines.append("capturing=\(recorder.isCapturing)")
        lines.append("bufferReady=\(recorder.isBufferReady)")
        lines.append("bufferedSeconds=\(recorder.bufferedSeconds)")
        lines.append("segmentCount=\(recorder.segmentCount)")
        lines.append("status=\(recorder.statusMessage)")
        lines.append("screenCapturePreflight=\(CGPreflightScreenCaptureAccess())")
        lines.append(recorder.internalDebugState())
        return lines.joined(separator: "\n")
    }
}

@MainActor
enum VoiceDiagnostics {
    static func logSnapshot(voice: VoiceCommandListener) {
        ClippyDebugLog.shared.log("Voice", "Diagnostics snapshot:")
        for line in snapshot(voice: voice).components(separatedBy: "\n") {
            ClippyDebugLog.shared.log("Voice", line)
        }
    }

    static func snapshot(voice: VoiceCommandListener) -> String {
        let settings = AppSettings.shared
        var lines: [String] = []
        lines.append("voiceCommandsEnabled=\(settings.voiceCommandsEnabled)")
        lines.append("isListening=\(voice.isListening)")
        lines.append("status=\(voice.statusMessage)")
        lines.append("speechAuthorization=\(speechAuthLabel(voice.authorizationStatus))")
        lines.append("microphoneAuthorized=\(voice.microphoneAuthorized)")
        lines.append("micAVCaptureStatus=\(micAuthLabel(AVCaptureDevice.authorizationStatus(for: .audio)))")
        lines.append("activeMicrophone=\(voice.activeMicrophoneName)")
        lines.append("preferredMicUID=\(settings.preferredMicrophoneUID.isEmpty ? "(system default)" : settings.preferredMicrophoneUID)")
        if let heard = voice.lastHeardPhrase, !heard.isEmpty {
            lines.append("lastHeard=\"\(heard)\"")
        }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        lines.append("recognizerAvailable=\(recognizer?.isAvailable ?? false)")
        if #available(macOS 13.0, *) {
            lines.append("onDeviceRecognition=\(recognizer?.supportsOnDeviceRecognition ?? false)")
        }
        return lines.joined(separator: "\n")
    }

    private static func speechAuthLabel(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private static func micAuthLabel(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
