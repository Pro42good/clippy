import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recorder: ScreenRecorder
    @EnvironmentObject private var voice: VoiceCommandListener

    @State private var selectedTab: Tab = .library
    @State private var pulse = false

    enum Tab: String, CaseIterable {
        case library = "Library"
        case settings = "Settings"
    }

    var body: some View {
        ZStack {
            ClippyTheme.background.ignoresSafeArea()

            RadialGradient(
                colors: [ClippyTheme.accent.opacity(0.08), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                tabBar
                tabContent
            }

            if coordinator.showClipSavedBanner {
                clipSavedBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .alert("Clippy", isPresented: Binding(
            get: { coordinator.errorMessage != nil },
            set: { if !$0 { coordinator.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(ClippyTheme.accent.opacity(0.12))
                    .frame(width: 52, height: 52)
                    .scaleEffect(pulse ? 1.06 : 0.94)
                    .clippyGlow(isActive: recorder.isBufferReady)

                Image("ClippyLogo")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(ClippyTheme.accent.opacity(0.35), lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Clippy")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(ClippyTheme.textPrimary)
                Text(recorder.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(ClippyTheme.textSecondary)
            }

            Spacer()

            statusPill

            Button {
                Task { await coordinator.triggerClip(source: .button) }
            } label: {
                HStack(spacing: 8) {
                    if recorder.isClipping {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                    } else {
                        Image(systemName: "film.stack")
                    }
                    Text(recorder.isClipping ? "Clipping…" : (recorder.isBufferReady ? "Clip Now" : "Buffering…"))
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(recorder.isBufferReady ? ClippyTheme.accent : ClippyTheme.accentDim)
                .foregroundStyle(.black)
                .clipShape(Capsule())
                .clippyGlow(isActive: recorder.isBufferReady)
            }
            .buttonStyle(.plain)
            .disabled(recorder.isClipping || !recorder.isBufferReady)
            .scaleEffect(recorder.isClipping ? 0.96 : 1)
            .animation(ClippyTheme.spring, value: recorder.isClipping)
            .animation(ClippyTheme.spring, value: recorder.isBufferReady)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(recorder.isBufferReady ? ClippyTheme.accent : .orange)
                .frame(width: 8, height: 8)
                .scaleEffect(recorder.isCapturing && pulse ? 1.3 : 1)
            Text(recorder.isBufferReady ? "Buffer active" : "Buffering")
                .font(.caption.weight(.semibold))
            Divider().frame(height: 14)
            Text(settings.hotkey.displayString)
                .font(.caption.monospaced())
            if voice.isListening {
                Divider().frame(height: 14)
                Image(systemName: "waveform")
                    .foregroundStyle(ClippyTheme.accent)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(ClippyTheme.surfaceElevated)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(ClippyTheme.border))
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(ClippyTheme.spring) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.headline)
                        .foregroundStyle(selectedTab == tab ? .black : ClippyTheme.textSecondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(selectedTab == tab ? ClippyTheme.accent : ClippyTheme.surface)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Last \(settings.clipDuration.shortLabel)")
                .font(.caption.weight(.medium))
                .foregroundStyle(ClippyTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(ClippyTheme.surface)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .library:
            LibraryView()
                .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
        case .settings:
            SettingsView()
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        }
    }

    private var clipSavedBanner: some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(ClippyTheme.accent)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clip saved")
                        .font(.headline)
                    if let clip = coordinator.lastClip {
                        Text(clip.title)
                            .font(.caption)
                            .foregroundStyle(ClippyTheme.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(16)
            .background(ClippyTheme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClippyTheme.accent.opacity(0.4)))
            .padding(.horizontal, 28)
            .padding(.top, 12)
            Spacer()
        }
    }
}
