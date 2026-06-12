import AVFoundation
import SwiftUI

struct ClipCard: View {
    let clip: Clip
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onOpen) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black)
                        .frame(height: 140)

                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        ProgressView()
                            .tint(ClippyTheme.accent)
                    }

                    VStack {
                        Spacer()
                        HStack {
                            Label(formatDuration(clip.duration), systemImage: "clock")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.65))
                                .clipShape(Capsule())
                            Spacer()
                        }
                        .padding(8)
                    }

                    if isHovering {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.25))
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(radius: 8)
                    }
                }
                .overlay {
                    if isHovering {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(ClippyTheme.accent.opacity(0.8), lineWidth: 2)
                    }
                }
            }
            .buttonStyle(.plain)

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(clip.title)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(ClippyTheme.textPrimary)

                    Text(clip.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(ClippyTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            HStack {
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(ClippySecondaryButtonStyle())
            }
        }
        .padding(14)
        .clippyCard(highlighted: isHovering)
        .scaleEffect(isHovering ? 1.02 : 1)
        .animation(ClippyTheme.spring, value: isHovering)
        .onHover { isHovering = $0 }
        .task {
            thumbnail = await ThumbnailGenerator.shared.image(for: clip.fileURL)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let total = Int(round(duration))
        let minutes = total / 60
        let seconds = total % 60
        if minutes > 0 {
            return "\(minutes):\(String(format: "%02d", seconds))"
        }
        return "0:\(String(format: "%02d", seconds))"
    }
}

struct ClippySecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ClippyTheme.surfaceElevated)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(ClippyTheme.border))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(ClippyTheme.spring, value: configuration.isPressed)
    }
}

@MainActor
final class ThumbnailGenerator {
    static let shared = ThumbnailGenerator()

    func image(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        let time = CMTime(seconds: 0.4, preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
                if let cgImage {
                    continuation.resume(returning: NSImage(cgImage: cgImage, size: .zero))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

import AppKit
