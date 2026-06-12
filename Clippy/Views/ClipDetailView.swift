import SwiftUI

struct ClipDetailView: View {
    let clip: Clip

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var clipManager: ClipManager
    @State private var title: String
    @State private var appeared = false

    init(clip: Clip) {
        self.clip = clip
        _title = State(initialValue: clip.title)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Clip title", text: $title, onCommit: saveTitle)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(ClippyTheme.accent)
            }
            .padding(24)

            ClipPlayerView(url: clip.fileURL)
                .id(clip.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .scaleEffect(appeared ? 1 : 0.96)
                .opacity(appeared ? 1 : 0)

            HStack(spacing: 12) {
                Button {
                    clipManager.exportClip(clip)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(ClippySecondaryButtonStyle())

                Button {
                    clipManager.revealInFinder(clip)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(ClippySecondaryButtonStyle())

                Spacer()

                Text(clip.createdAt.formatted(date: .complete, time: .standard))
                    .font(.caption)
                    .foregroundStyle(ClippyTheme.textSecondary)
            }
            .padding(24)
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(ClippyTheme.background)
        .onAppear {
            withAnimation(ClippyTheme.spring) {
                appeared = true
            }
        }
    }

    private func saveTitle() {
        clipManager.renameClip(clip, title: title)
    }
}
