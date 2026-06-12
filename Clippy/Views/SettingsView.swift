import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var voice: VoiceCommandListener
    @EnvironmentObject private var recorder: ScreenRecorder
    @ObservedObject private var debugLog = ClippyDebugLog.shared
    @ObservedObject private var audioDevices = AudioDeviceStore.shared
    @ObservedObject private var displayStore = DisplayStore.shared

    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                settingsSection(title: "Clip Length", icon: "timer") {
                    Picker("Duration", selection: $settings.clipDuration) {
                        ForEach(ClipDuration.allCases) { duration in
                            Text(duration.label).tag(duration)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Clips use up to this length. If the buffer has less, Clippy saves whatever is available.")
                        .font(.caption)
                        .foregroundStyle(ClippyTheme.textSecondary)
                }

                settingsSection(title: "Video Quality", icon: "film") {
                    Picker("Resolution", selection: $settings.captureResolution) {
                        ForEach(CaptureResolution.allCases) { resolution in
                            Text(resolution.label).tag(resolution)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.captureResolution) { _, _ in
                        coordinator.refreshCaptureQuality()
                    }

                    Picker("Frame rate", selection: $settings.captureFrameRate) {
                        ForEach(CaptureFrameRate.allCases) { rate in
                            Text(rate.label).tag(rate)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.captureFrameRate) { _, _ in
                        coordinator.refreshCaptureQuality()
                    }

                    Text("Default is 720p at 30 fps to keep Clippy light on your system. Higher settings use more CPU and disk.")
                        .font(.caption)
                        .foregroundStyle(ClippyTheme.textSecondary)
                }

                settingsSection(title: "Display", icon: "display") {
                    Picker("Record from", selection: $settings.preferredDisplayID) {
                        ForEach(displayStore.displays) { display in
                            Text(display.label).tag(display.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: settings.preferredDisplayID) { _, _ in
                        coordinator.refreshDisplay()
                    }

                    Text("Choose which monitor Clippy buffers and clips. Changing this restarts capture.")
                        .font(.caption)
                        .foregroundStyle(ClippyTheme.textSecondary)
                }

                settingsSection(title: "Keyboard Shortcut", icon: "command") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Press a new combination to change the global clip shortcut.")
                            .font(.caption)
                            .foregroundStyle(ClippyTheme.textSecondary)
                        KeyRecorderView(binding: $settings.hotkey)
                            .onChange(of: settings.hotkey) { _, _ in
                                coordinator.refreshHotkey()
                            }
                    }
                }

                settingsSection(title: "Audio", icon: "speaker.wave.3") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Clips include system audio from the recorded display plus your microphone.")
                            .font(.caption)
                            .foregroundStyle(ClippyTheme.textSecondary)

                        Text("System audio output")
                            .font(.subheadline.weight(.semibold))
                        Picker("System audio output", selection: $settings.preferredAudioOutputUID) {
                            ForEach(audioDevices.outputDevices) { device in
                                Text(device.name).tag(device.uid)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: settings.preferredAudioOutputUID) { _, _ in
                            coordinator.refreshCaptureQuality()
                        }
                        Text("Sets macOS default output so app audio routes through this device while Clippy records.")
                            .font(.caption)
                            .foregroundStyle(ClippyTheme.textSecondary)

                        Text("Microphone")
                            .font(.subheadline.weight(.semibold))
                        Picker("Microphone", selection: $settings.preferredMicrophoneUID) {
                            ForEach(audioDevices.inputDevices) { device in
                                Text(device.name).tag(device.uid)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: settings.preferredMicrophoneUID) { _, _ in
                            coordinator.refreshMicrophone()
                            coordinator.refreshCaptureQuality()
                        }
                        Text("Using: \(voice.activeMicrophoneName)")
                            .font(.caption)
                            .foregroundStyle(ClippyTheme.textSecondary)
                    }
                }

                settingsSection(title: "Voice Commands", icon: "waveform") {
                    Toggle("Listen for \"Clippy, do your thing\" and \"Clippy, clip that\"", isOn: $settings.voiceCommandsEnabled)
                        .toggleStyle(.switch)
                        .tint(ClippyTheme.accent)
                        .onChange(of: settings.voiceCommandsEnabled) { _, _ in
                            coordinator.refreshVoiceListening()
                        }

                    HStack(spacing: 8) {
                        Circle()
                            .fill(voice.isListening ? ClippyTheme.accent : ClippyTheme.textSecondary)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voice.statusMessage)
                                .font(.caption)
                                .foregroundStyle(ClippyTheme.textSecondary)
                            if let err = voice.lastVoiceError, !err.isEmpty {
                                Text("Error: \(err)")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .lineLimit(3)
                            }
                            if let heard = voice.lastHeardPhrase, !heard.isEmpty {
                                Text("Heard: \"\(heard)\"")
                                    .font(.caption2)
                                    .foregroundStyle(ClippyTheme.accentDim)
                                    .lineLimit(2)
                            }
                        }
                    }
                }

                settingsSection(title: "Feedback", icon: "speaker.wave.2") {
                    Toggle("Play sound when clipping", isOn: $settings.soundEnabled)
                        .toggleStyle(.switch)
                        .tint(ClippyTheme.accent)
                }

                settingsSection(title: "Debug Log", icon: "ladybug") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Detailed errors from clipping, recording, and voice recognition appear here.")
                            .font(.caption)
                            .foregroundStyle(ClippyTheme.textSecondary)

                        if !recorder.lastClipDebugSummary.isEmpty {
                            Text("Last clip attempt")
                                .font(.caption.weight(.semibold))
                            Text(recorder.lastClipDebugSummary)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(ClippyTheme.textSecondary)
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        HStack(spacing: 10) {
                            Button("Refresh diagnostics") {
                                ClippyDebugLog.shared.log("Debug", "Manual refresh")
                                ClippyDebugLog.shared.log("Debug", RecorderDiagnostics.snapshot(recorder: recorder))
                                VoiceDiagnostics.logSnapshot(voice: voice)
                            }
                            .buttonStyle(ClippySecondaryButtonStyle())

                            Button("Copy log") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(debugLog.exportText, forType: .string)
                            }
                            .buttonStyle(ClippySecondaryButtonStyle())

                            Button("Clear") {
                                debugLog.clear()
                            }
                            .buttonStyle(ClippySecondaryButtonStyle())
                        }

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                if debugLog.entries.isEmpty {
                                    Text("No log entries yet. Try clipping or enabling voice commands.")
                                        .font(.caption)
                                        .foregroundStyle(ClippyTheme.textSecondary)
                                } else {
                                    ForEach(debugLog.entries) { entry in
                                        Text(entry.formatted)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(ClippyTheme.textSecondary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 280)
                        .padding(10)
                        .background(Color.black.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                settingsSection(title: "Permissions", icon: "lock.shield") {
                    VStack(alignment: .leading, spacing: 10) {
                        permissionRow(
                            title: "Screen Recording",
                            detail: "Required to buffer your screen in the background.",
                            actionTitle: "Open Settings"
                        ) {
                            openPrivacyPane("Privacy_ScreenCapture")
                        }
                        permissionRow(
                            title: "Microphone & Speech",
                            detail: "Required for voice-triggered clips.",
                            actionTitle: "Open Settings"
                        ) {
                            openPrivacyPane("Privacy_Microphone")
                        }
                        permissionRow(
                            title: "Speech Recognition",
                            detail: "Required to understand voice commands.",
                            actionTitle: "Open Settings"
                        ) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            .padding(28)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
        }
        .onAppear {
            audioDevices.refreshDevices()
            Task { await displayStore.refreshDisplays() }
            withAnimation(ClippyTheme.spring) {
                appeared = true
            }
        }
    }

    private var voiceStatusText: String {
        voice.statusMessage
    }

    @ViewBuilder
    private func settingsSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(ClippyTheme.accent)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clippyCard()
    }

    private func permissionRow(title: String, detail: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(ClippyTheme.textSecondary)
            }
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(ClippySecondaryButtonStyle())
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

import AppKit
