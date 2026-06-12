import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var clipManager: ClipManager
    @State private var selectedClip: Clip?
    @State private var appeared = false

    private let columns = [
        GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 18)
    ]

    var body: some View {
        Group {
            if clipManager.clips.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(Array(clipManager.clips.enumerated()), id: \.element.id) { index, clip in
                            ClipCard(clip: clip) {
                                selectedClip = clip
                            } onDelete: {
                                withAnimation(ClippyTheme.spring) {
                                    clipManager.deleteClip(clip)
                                }
                            }
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 24)
                            .animation(ClippyTheme.spring.delay(Double(index) * 0.04), value: appeared)
                        }
                    }
                    .padding(28)
                }
            }
        }
        .sheet(item: $selectedClip) { clip in
            ClipDetailView(clip: clip)
        }
        .onAppear {
            withAnimation(ClippyTheme.spring) {
                appeared = true
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "film")
                .font(.system(size: 54))
                .foregroundStyle(ClippyTheme.accent)
                .symbolEffect(.pulse, isActive: true)
            Text("No clips yet")
                .font(.title2.bold())
            Text("Press \(AppSettings.shared.hotkey.displayString) or say \"Clippy, clip that\" to save your first clip.")
                .multilineTextAlignment(.center)
                .foregroundStyle(ClippyTheme.textSecondary)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
