import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

struct RecordingSegment {
    let url: URL
    let startTime: Date
    let duration: TimeInterval
    let frameCount: Int
}

enum ScreenRecorderError: LocalizedError {
    case noDisplay
    case permissionDenied
    case exportFailed(String?)
    case noSegments

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display available for capture."
        case .permissionDenied: return "Screen Recording permission is required — enable Clippy in System Settings."
        case .exportFailed(let detail):
            if let detail, !detail.isEmpty { return detail }
            return "Failed to export the clip."
        case .noSegments: return "No recording buffer available yet — wait a few seconds for the buffer to fill. Open Settings → Debug Log for details."
        }
    }
}

// MARK: - Frame validation (required for manual AVAssetWriter path)

private enum SCFrameValidator {
    static func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard sampleBuffer.isValid else { return false }
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first else { return false }
        guard let statusRaw = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else { return false }
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return false }
        return true
    }
}

// MARK: - Rolling buffer segment writer

private enum SegmentAudioTrack {
    case system
    case microphone
}

private final class SegmentWriter: @unchecked Sendable {
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneAudioInput: AVAssetWriterInput?
    private var segmentURL: URL?
    private var segmentStartedAt = Date()
    private var hasStartedSession = false
    private var isFinalizing = false
    private var frameIndex: Int64 = 0
    private var firstVideoPTS: CMTime?
    private var firstSystemAudioPTS: CMTime?
    private var firstMicrophoneAudioPTS: CMTime?
    private var pausedForClip = false
    private var clipBoundaryWallTime: Date?

    private(set) var pendingFinalizationURLs: Set<URL> = []
    private(set) var currentSegmentURL: URL?

    private var systemAudioSampleCount: Int64 = 0
    private var microphoneAudioSampleCount: Int64 = 0
    private let writeLock = NSLock()

    let segmentDuration: TimeInterval
    let captureFPS: Int
    let videoBitrate: Int
    let directory: URL
    let onSegmentFinished: (RecordingSegment?) -> Void

    init(
        directory: URL,
        segmentDuration: TimeInterval,
        captureFPS: Int,
        videoBitrate: Int,
        onSegmentFinished: @escaping (RecordingSegment?) -> Void
    ) {
        self.directory = directory
        self.segmentDuration = segmentDuration
        self.captureFPS = max(captureFPS, 1)
        self.videoBitrate = videoBitrate
        self.onSegmentFinished = onSegmentFinished
    }

    typealias SegmentCompletion = (RecordingSegment?) -> Void

    var writtenFrameCount: Int { Int(frameIndex) }

    private func openNewSegmentFile() {
        let url = directory.appendingPathComponent("seg_\(UUID().uuidString).mov")
        segmentURL = url
        currentSegmentURL = url
        segmentStartedAt = Date()
        hasStartedSession = false
        frameIndex = 0
        firstVideoPTS = nil
        firstSystemAudioPTS = nil
        firstMicrophoneAudioPTS = nil
        systemAudioSampleCount = 0
        microphoneAudioSampleCount = 0
        videoInput = nil
        systemAudioInput = nil
        microphoneAudioInput = nil

        if let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) {
            writer.shouldOptimizeForNetworkUse = false
            self.writer = writer
        } else {
            self.writer = nil
        }
    }

    func setClipBoundary(wallTime: Date) {
        clipBoundaryWallTime = wallTime
        pausedForClip = true
    }

    func processVideo(_ sampleBuffer: CMSampleBuffer) {
        writeLock.lock()
        defer { writeLock.unlock() }
        processVideoLocked(sampleBuffer)
    }

    func processSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        writeLock.lock()
        defer { writeLock.unlock() }
        processSystemAudioLocked(sampleBuffer)
    }

    func processMicrophoneAudio(_ sampleBuffer: CMSampleBuffer) {
        writeLock.lock()
        defer { writeLock.unlock() }
        processMicrophoneAudioLocked(sampleBuffer)
        onMicrophoneSample?(sampleBuffer)
    }

    var audioDiagnostics: String {
        "systemAudioSamples=\(systemAudioSampleCount) micAudioSamples=\(microphoneAudioSampleCount)"
    }

    private func processVideoLocked(_ sampleBuffer: CMSampleBuffer) {
        if let boundary = clipBoundaryWallTime, Date() >= boundary { return }
        guard !pausedForClip else { return }
        guard SCFrameValidator.isCompleteScreenFrame(sampleBuffer) else { return }
        if writer == nil, !isFinalizing { openNewSegmentFile() }
        guard let writer, !isFinalizing, writer.status != .failed else { return }

        if videoInput == nil {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            let width = max(2, Int(dimensions.width) & ~1)
            let height = max(2, Int(dimensions.height) & ~1)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: videoBitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: captureFPS * 2,
                    AVVideoAllowFrameReorderingKey: false
                ]
            ]
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: settings,
                sourceFormatHint: formatDescription
            )
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { return }
            writer.add(input)
            videoInput = input
        }

        startSessionIfNeeded(on: writer)

        guard let videoInput else { return }
        var waitAttempts = 0
        while !videoInput.isReadyForMoreMediaData, waitAttempts < 200 {
            Thread.sleep(forTimeInterval: 0.003)
            waitAttempts += 1
        }
        guard videoInput.isReadyForMoreMediaData else { return }

        let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstVideoPTS == nil { firstVideoPTS = samplePTS }
        guard let base = firstVideoPTS,
              let retimed = retimestampVideo(sampleBuffer, base: base) else { return }
        guard videoInput.append(retimed) else { return }
        frameIndex += 1

        if Date().timeIntervalSince(segmentStartedAt) >= segmentDuration {
            finalizeSegment(completion: nil)
        }
    }

    private func processSystemAudioLocked(_ sampleBuffer: CMSampleBuffer) {
        guard processAudioLocked(sampleBuffer, track: .system) else { return }
        systemAudioSampleCount += 1
    }

    private func processMicrophoneAudioLocked(_ sampleBuffer: CMSampleBuffer) {
        guard processAudioLocked(sampleBuffer, track: .microphone) else { return }
        microphoneAudioSampleCount += 1
    }

    var onMicrophoneSample: ((CMSampleBuffer) -> Void)?

    @discardableResult
    private func processAudioLocked(_ sampleBuffer: CMSampleBuffer, track: SegmentAudioTrack) -> Bool {
        if let boundary = clipBoundaryWallTime, Date() >= boundary { return false }
        guard !pausedForClip else { return false }
        guard isValidAudioSample(sampleBuffer) else { return false }
        // Never open a segment or start the writer from audio — video must initialize the file first.
        guard writer != nil, hasStartedSession, videoInput != nil, !isFinalizing else { return false }
        guard let writer, writer.status != .failed else { return false }

        let input: AVAssetWriterInput?
        switch track {
        case .system:
            if systemAudioInput == nil {
                systemAudioInput = makeAudioInput(for: sampleBuffer, writer: writer)
            }
            input = systemAudioInput
        case .microphone:
            if microphoneAudioInput == nil {
                microphoneAudioInput = makeAudioInput(for: sampleBuffer, writer: writer)
            }
            input = microphoneAudioInput
        }

        guard let input else { return false }

        var waitAttempts = 0
        while !input.isReadyForMoreMediaData, waitAttempts < 200 {
            Thread.sleep(forTimeInterval: 0.003)
            waitAttempts += 1
        }
        guard input.isReadyForMoreMediaData else { return false }

        let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        switch track {
        case .system:
            if firstSystemAudioPTS == nil { firstSystemAudioPTS = samplePTS }
            guard let base = firstSystemAudioPTS,
                  let retimed = retimestampAudio(sampleBuffer, base: base) else { return false }
            return input.append(retimed)
        case .microphone:
            if firstMicrophoneAudioPTS == nil { firstMicrophoneAudioPTS = samplePTS }
            guard let base = firstMicrophoneAudioPTS,
                  let retimed = retimestampAudio(sampleBuffer, base: base) else { return false }
            return input.append(retimed)
        }
    }

    private func isValidAudioSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferIsValid(sampleBuffer) else { return false }
        if CMSampleBufferGetNumSamples(sampleBuffer) > 0 { return true }
        guard CMSampleBufferGetFormatDescription(sampleBuffer) != nil else { return false }
        return CMSampleBufferGetTotalSampleSize(sampleBuffer) > 0
    }

    private func makeAudioInput(for sampleBuffer: CMSampleBuffer, writer: AVAssetWriter) -> AVAssetWriterInput? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }

        let passthrough = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formatDescription)
        passthrough.expectsMediaDataInRealTime = true
        if writer.canAdd(passthrough) {
            writer.add(passthrough)
            return passthrough
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let encoded = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        encoded.expectsMediaDataInRealTime = true
        guard writer.canAdd(encoded) else { return nil }
        writer.add(encoded)
        return encoded
    }

    private func startSessionIfNeeded(on writer: AVAssetWriter) {
        guard !hasStartedSession else { return }
        guard videoInput != nil else { return }
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: .zero)
        hasStartedSession = true
    }

    private func retimestampVideo(_ sampleBuffer: CMSampleBuffer, base: CMTime) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let local = CMTimeSubtract(pts, base)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(captureFPS))
        var timing = CMSampleTimingInfo(
            duration: duration.isValid && duration.seconds > 0 ? duration : frameDuration,
            presentationTimeStamp: local,
            decodeTimeStamp: .invalid
        )
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &output
        )
        guard status == noErr else { return nil }
        return output
    }

    private func retimestampAudio(_ sampleBuffer: CMSampleBuffer, base: CMTime) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let local = CMTimeSubtract(pts, base)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        var timing = CMSampleTimingInfo(
            duration: duration.isValid ? duration : CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: local,
            decodeTimeStamp: .invalid
        )
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &output
        )
        guard status == noErr else { return nil }
        return output
    }

    func pauseForClip(completion: SegmentCompletion?) {
        pausedForClip = true
        if writer != nil {
            finalizeSegment(completion: completion)
        } else {
            completion?(nil)
        }
    }

    func resumeAfterClip() {
        pausedForClip = false
        clipBoundaryWallTime = nil
        guard writer == nil, !isFinalizing else { return }
        openNewSegmentFile()
    }

    func finalizeSegment(completion: SegmentCompletion?) {
        guard let writer, let url = segmentURL, !isFinalizing else {
            completion?(nil)
            return
        }
        isFinalizing = true
        let startedAt = segmentStartedAt
        let framesWritten = frameIndex
        let hadSession = hasStartedSession
        pendingFinalizationURLs.insert(url)
        currentSegmentURL = nil

        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneAudioInput?.markAsFinished()
        self.writer = nil
        videoInput = nil
        systemAudioInput = nil
        microphoneAudioInput = nil
        segmentURL = nil
        hasStartedSession = false

        guard hadSession, framesWritten > 0 else {
            pendingFinalizationURLs.remove(url)
            try? FileManager.default.removeItem(at: url)
            isFinalizing = false
            completion?(nil)
            return
        }

        writer.finishWriting {
            self.pendingFinalizationURLs.remove(url)
            let segment: RecordingSegment?
            if writer.status == .completed,
               Self.fileSize(at: url) > 500,
               ClipExporter.hasReadableVideoSync(at: url) {
                let measured = ClipExporter.measuredDurationSync(at: url)
                    ?? max(Double(framesWritten) / Double(self.captureFPS), 0.1)
                segment = RecordingSegment(url: url, startTime: startedAt, duration: measured, frameCount: Int(framesWritten))
            } else {
                try? FileManager.default.removeItem(at: url)
                segment = nil
            }
            self.isFinalizing = false
            self.onSegmentFinished(segment)
            completion?(segment)
        }
    }

    func startNewSegment() {
        guard !isFinalizing else { return }
        if writer != nil {
            finalizeSegment(completion: nil)
        } else {
            openNewSegmentFile()
        }
    }

    private static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - Screen recorder

@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    static let shared = ScreenRecorder()

    @Published private(set) var isCapturing = false
    @Published private(set) var statusMessage = "Starting capture…"
    @Published private(set) var isClipping = false
    @Published private(set) var bufferedSeconds: TimeInterval = 0
    @Published private(set) var isBufferReady = false
    @Published private(set) var segmentCount: Int = 0
    @Published private(set) var lastClipDebugSummary: String = ""

    private var stream: SCStream?
    private var segments: [RecordingSegment] = []
    private let segmentDuration: TimeInterval = 5
    private let maxBufferDuration: TimeInterval = 60

    private var segmentWriter: SegmentWriter?
    private var bufferTicker: Task<Void, Never>?
    private var activeCaptureFPS: Int = 30

    private let bufferDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Clippy/Buffer", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private let processingQueue = DispatchQueue(label: "com.clippy.recorder", qos: .userInitiated)

    private override init() {
        super.init()
    }

    func logRecorder(_ message: String) {
        ClippyDebugLog.shared.log("Recorder", message)
    }

    func internalDebugState() -> String {
        let protected = protectedSegmentURLs()
        let validCount = segments.filter { isValidSegmentFile($0.url) }.count
        var lines: [String] = []
        lines.append("writtenFrames=\(segmentWriter?.writtenFrameCount ?? 0)")
        if let writer = segmentWriter {
            lines.append(writer.audioDiagnostics)
        }
        lines.append("bufferDir=\(bufferDirectory.path)")
        lines.append("segmentsInMemory=\(segments.count) validOnDisk=\(validCount) pendingProtected=\(protected.count)")
        for segment in segments.suffix(5) {
            let size = fileSize(at: segment.url)
            let valid = isValidSegmentFile(segment.url)
            lines.append("  - \(segment.url.lastPathComponent) dur=\(String(format: "%.1f", segment.duration))s size=\(size) valid=\(valid)")
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: bufferDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
            let segFiles = files.filter { $0.lastPathComponent.hasPrefix("seg_") }
            lines.append("segFilesOnDisk=\(segFiles.count)")
            for file in segFiles.suffix(5) {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                lines.append("  - \(file.lastPathComponent) size=\(size)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func logBufferSnapshot(_ phase: String) {
        logRecorder("--- clip \(phase) ---")
        logRecorder(RecorderDiagnostics.snapshot(recorder: self).replacingOccurrences(of: "\n", with: " | "))
        logRecorder(internalDebugState().replacingOccurrences(of: "\n", with: " | "))
    }

    func requestScreenCaptureAccess() {
        if !CGPreflightScreenCaptureAccess() {
            statusMessage = "Allow Screen Recording for Clippy…"
            CGRequestScreenCaptureAccess()
        }
    }

    func restartCapture() async {
        await stopCapture()
        segments.removeAll()
        bufferedSeconds = 0
        isBufferReady = false
        segmentCount = 0
        purgeInvalidSegmentFilesOnDisk()
        await startCapture()
    }

    private func purgeInvalidSegmentFilesOnDisk() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: bufferDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix("seg_") {
            if !isValidSegmentFile(file) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func startCapture() async {
        guard !isCapturing else { return }

        requestScreenCaptureAccess()
        guard CGPreflightScreenCaptureAccess() else {
            statusMessage = "Enable Screen Recording for Clippy in System Settings"
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let preferredID = AppSettings.shared.preferredDisplayID
            guard let display = DisplayManager.resolveDisplay(id: preferredID, from: content.displays) else {
                statusMessage = "No display found"
                return
            }

            let displayIndex = content.displays.firstIndex(where: { $0.displayID == display.displayID }) ?? 0
            let displayName = DisplayManager.name(for: display, index: displayIndex)

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let captureSettings = AppSettings.shared
            let resolution = captureSettings.captureResolution
            let frameRate = captureSettings.captureFrameRate
            activeCaptureFPS = frameRate.rawValue

            let dimensions = resolution.dimensions(for: display)
            let config = SCStreamConfiguration()
            config.width = dimensions.width
            config.height = dimensions.height
            config.minimumFrameInterval = frameRate.minimumFrameInterval
            config.queueDepth = 8
            config.capturesAudio = true
            config.captureMicrophone = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
            config.showsCursor = true
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.scalesToFit = true

            if let micCaptureID = AudioDeviceManager.avCaptureMicrophoneID(
                forPreferredUID: captureSettings.preferredMicrophoneUID
            ) {
                config.microphoneCaptureDeviceID = micCaptureID
            }

            let stream = SCStream(filter: filter, configuration: config, delegate: self)

            let writer = SegmentWriter(
                directory: bufferDirectory,
                segmentDuration: segmentDuration,
                captureFPS: frameRate.rawValue,
                videoBitrate: resolution.videoBitrate
            ) { [weak self] segment in
                Task { @MainActor in
                    guard let self, let segment else { return }
                    if !self.segments.contains(where: { $0.url == segment.url }) {
                        self.handleSegmentFinished(segment)
                    }
                }
            }
            writer.onMicrophoneSample = { sampleBuffer in
                Task { @MainActor in
                    VoiceCommandListener.shared.ingestSharedCaptureMicrophoneSample(sampleBuffer)
                }
            }
            segmentWriter = writer
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: processingQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: processingQueue)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: processingQueue)

            if !captureSettings.preferredAudioOutputUID.isEmpty {
                AudioDeviceManager.setSystemDefaultOutputDevice(uid: captureSettings.preferredAudioOutputUID)
            }

            logRecorder(
                "Capture \(dimensions.width)x\(dimensions.height) @ \(frameRate.rawValue)fps | " +
                "output=\(AudioDeviceManager.resolvedOutputDeviceName(for: captureSettings.preferredAudioOutputUID)) | " +
                "mic=\(AudioDeviceManager.resolvedDeviceName(for: captureSettings.preferredMicrophoneUID)) | " +
                "micCaptureID=\(config.microphoneCaptureDeviceID ?? "default")"
            )

            try await stream.startCapture()
            self.stream = stream
            isCapturing = true
            statusMessage = "Buffering \(displayName)…"
            startBufferTicker()
            await VoiceCommandListener.shared.enableSharedCaptureMicrophoneIfNeeded()
        } catch {
            logRecorder("startCapture failed: \(error.localizedDescription)")
            ClippyDebugLog.shared.logError("Recorder", error, context: "startCapture")
            statusMessage = "Capture failed: \(error.localizedDescription)"
            isCapturing = false
        }
    }

    func stopCapture() async {
        bufferTicker?.cancel()
        if let stream {
            try? await stream.stopCapture()
        }
        await finalizeLegacySegment()
        stream = nil
        segmentWriter = nil
        isCapturing = false
        statusMessage = "Capture stopped"
        updateBufferState()
    }

    struct ClipResult {
        let url: URL
        let duration: TimeInterval
    }

    func createClip(maxDuration: TimeInterval) async throws -> ClipResult {
        isClipping = true
        defer { isClipping = false }

        logBufferSnapshot("start")

        // Drop any frames captured after the button press before finalizing the boundary segment.
        let clipBoundary = Date()
        processingQueue.sync { [weak self] in
            self?.segmentWriter?.setClipBoundary(wallTime: clipBoundary)
        }

        // Stop capture immediately so nothing after the button press is recorded.
        let boundarySegment = await pauseAndFinalizeAtClipBoundary()
        await waitForPendingFinalizations(timeout: 3.0)

        if let boundarySegment {
            let refreshed = refreshedSegment(boundarySegment)
            if fileSize(at: refreshed.url) > 500,
               !segments.contains(where: { $0.url == refreshed.url }) {
                segments.append(refreshed)
                segments.sort { $0.startTime < $1.startTime }
                pruneSegments()
            }
        }

        let sourceSegments = await playableSegmentsForClip(maxDuration: maxDuration)
        guard !sourceSegments.isEmpty else {
            let summary = buildClipFailureSummary(freshlyFinalized: boundarySegment, extra: "no playable segments in buffer")
            throw clipFailure("No recording buffer available yet — wait a few seconds for the buffer to fill.", summary: summary)
        }

        let availableDuration = sourceSegments.reduce(0) { $0 + $1.duration }
        let targetDuration = min(maxDuration, availableDuration)
        let exportURL = bufferDirectory.appendingPathComponent("export_\(UUID().uuidString).mp4")

        logRecorder("Exporting \(sourceSegments.count) segment(s), available=\(String(format: "%.2f", availableDuration))s target=\(String(format: "%.2f", targetDuration))s")

        do {
            try await ClipExporter.export(segments: sourceSegments, trimTo: targetDuration, outputURL: exportURL)
        } catch {
            ClippyDebugLog.shared.logError("Recorder", error, context: "export")
            let summary = buildClipFailureSummary(freshlyFinalized: boundarySegment, exportError: error)
            throw clipFailure(error.localizedDescription, summary: summary)
        }

        guard await ClipExporter.isPlayableVideo(at: exportURL) else {
            let summary = buildClipFailureSummary(freshlyFinalized: boundarySegment, extra: "export file not playable")
            throw clipFailure("Export produced an unplayable clip — try again.", summary: summary)
        }

        let exportedDuration = await ClipExporter.measuredDuration(at: exportURL) ?? targetDuration
        let clipDuration = min(maxDuration, exportedDuration)

        resumeCaptureAfterClip()
        updateBufferState()

        lastClipDebugSummary = "Clip OK — \(String(format: "%.1f", clipDuration))s (target \(Int(maxDuration))s) from \(sourceSegments.count) segment(s)"
        logRecorder(lastClipDebugSummary)
        return ClipResult(url: exportURL, duration: clipDuration)
    }

    private func waitForPendingFinalizations(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let pending = processingQueue.sync { segmentWriter?.pendingFinalizationURLs.count ?? 0 }
            if pending == 0 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func pauseAndFinalizeAtClipBoundary() async -> RecordingSegment? {
        await withCheckedContinuation { continuation in
            processingQueue.async { [weak self] in
                self?.segmentWriter?.pauseForClip { segment in
                    Task { @MainActor in
                        continuation.resume(returning: segment)
                    }
                } ?? continuation.resume(returning: nil)
            }
        }
    }

    private func resumeCaptureAfterClip() {
        processingQueue.async { [weak self] in
            self?.segmentWriter?.resumeAfterClip()
        }
        logRecorder("Resumed recording after clip attempt")
    }

    private func playableSegmentsForClip(maxDuration: TimeInterval) async -> [RecordingSegment] {
        var byURL = [URL: RecordingSegment]()
        for segment in segments {
            byURL[segment.url] = refreshedSegment(segment)
        }
        for segment in discoverSegmentsOnDisk() {
            byURL[segment.url] = refreshedSegment(segment)
        }

        var playable: [RecordingSegment] = []
        for segment in byURL.values.sorted(by: { $0.startTime < $1.startTime }) {
            guard isValidSegmentFile(segment.url) else {
                logRecorder("Skipping invalid segment for clip: \(segment.url.lastPathComponent)")
                continue
            }
            playable.append(refreshedSegment(segment))
        }

        let selected = segmentsForDuration(maxDuration, from: playable)
        logRecorder("Clip segment pick: \(playable.count) playable → \(selected.count) selected, durations=\(selected.map { String(format: "%.1f", $0.duration) }.joined(separator: "+"))")
        return selected
    }

    private func refreshedSegment(_ segment: RecordingSegment) -> RecordingSegment {
        guard let measured = measuredDuration(for: segment.url), measured > 0.01 else { return segment }
        return RecordingSegment(
            url: segment.url,
            startTime: segment.startTime,
            duration: measured,
            frameCount: segment.frameCount
        )
    }

    private func buildClipFailureSummary(freshlyFinalized: RecordingSegment?, exportError: Error? = nil, extra: String? = nil) -> String {
        var lines = [RecorderDiagnostics.snapshot(recorder: self), internalDebugState()]
        if let freshlyFinalized {
            lines.append("freshSegment: \(freshlyFinalized.url.lastPathComponent) dur=\(freshlyFinalized.duration) size=\(fileSize(at: freshlyFinalized.url))")
        } else {
            lines.append("freshSegment: nil")
        }
        if let exportError { lines.append("exportError: \(exportError.localizedDescription)") }
        if let extra { lines.append(extra) }
        return lines.joined(separator: "\n")
    }

    private func resumeRecordingAfterClipAttempt() {
        resumeCaptureAfterClip()
    }

    func ingestSegment(_ segment: RecordingSegment) {
        guard !segments.contains(where: { $0.url == segment.url }) else { return }
        handleSegmentFinished(segment)
    }

    private func handleSegmentFinished(_ segment: RecordingSegment) {
        let segment = refreshedSegment(segment)
        guard ClipExporter.isValidSegmentFile(at: segment.url) else {
            logRecorder("Ignoring invalid segment: \(segment.url.lastPathComponent) size=\(fileSize(at: segment.url))")
            try? FileManager.default.removeItem(at: segment.url)
            return
        }
        segments.append(segment)
        let audioTrackCount = AVURLAsset(url: segment.url).tracks(withMediaType: .audio).count
        logRecorder(
            "Segment ingested \(segment.url.lastPathComponent) audioTracks=\(audioTrackCount) " +
            (processingQueue.sync { segmentWriter?.audioDiagnostics } ?? "")
        )
        pruneSegments()
        updateBufferState()
    }

    private func startBufferTicker() {
        bufferTicker?.cancel()
        bufferTicker = Task { @MainActor in
            while !Task.isCancelled, isCapturing {
                updateBufferState()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func finalizeLegacySegment() async {
        let finished: RecordingSegment? = await withCheckedContinuation { continuation in
            processingQueue.async { [weak self] in
                self?.segmentWriter?.finalizeSegment { segment in
                    continuation.resume(returning: segment)
                } ?? continuation.resume(returning: nil)
            }
        }
        if let finished { ingestSegment(finished) }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    private func validSegmentsForClip(maxDuration: TimeInterval) -> [RecordingSegment] {
        var byURL = [URL: RecordingSegment]()
        for segment in segments where isValidSegmentFile(segment.url) {
            byURL[segment.url] = segment
        }
        for segment in discoverSegmentsOnDisk() where isValidSegmentFile(segment.url) {
            byURL[segment.url] = segment
        }
        let merged = byURL.values.sorted { $0.startTime < $1.startTime }
        return segmentsForDuration(maxDuration, from: merged)
    }

    private func segmentsForDuration(_ duration: TimeInterval, from source: [RecordingSegment]) -> [RecordingSegment] {
        guard !source.isEmpty else { return [] }
        var total: TimeInterval = 0
        var selected: [RecordingSegment] = []
        for segment in source.reversed() {
            let refreshed = refreshedSegment(segment)
            selected.insert(refreshed, at: 0)
            total += refreshed.duration
            if total >= duration - 0.05 { break }
        }
        return selected
    }

    private func isValidSegmentFile(_ url: URL) -> Bool {
        ClipExporter.isValidSegmentFile(at: url)
    }

    private func clipFailure(_ userMessage: String, summary: String) -> ScreenRecorderError {
        lastClipDebugSummary = summary
        logRecorder("CLIP FAILED — \(userMessage)\n\(summary)")
        resumeCaptureAfterClip()
        updateBufferState()
        return .exportFailed(userMessage)
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func discoverSegmentsOnDisk() -> [RecordingSegment] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: bufferDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return [] }

        return files
            .filter { ($0.pathExtension == "mov" || $0.pathExtension == "mp4") && $0.lastPathComponent.hasPrefix("seg_") }
            .compactMap { url -> RecordingSegment? in
                guard isValidSegmentFile(url) else { return nil }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let modified = values?.contentModificationDate ?? Date()
                let duration = measuredDuration(for: url) ?? segmentDuration
                return RecordingSegment(url: url, startTime: modified, duration: duration, frameCount: 0)
            }
            .sorted { $0.startTime < $1.startTime }
    }

    private func measuredDuration(for url: URL) -> TimeInterval? {
        if let existing = segments.first(where: { $0.url == url }), existing.duration > 0 {
            return existing.duration
        }
        let asset = AVURLAsset(url: url)
        if asset.duration.isValid, asset.duration.seconds > 0.01 {
            return asset.duration.seconds
        }
        return nil
    }

    private func protectedSegmentURLs() -> Set<URL> {
        processingQueue.sync {
            var urls = Set<URL>()
            if let writer = segmentWriter {
                urls.formUnion(writer.pendingFinalizationURLs)
                if let current = writer.currentSegmentURL {
                    urls.insert(current)
                }
            }
            return urls
        }
    }

    private func purgeStaleSegments() {
        let protected = protectedSegmentURLs()
        let before = segments.count
        segments = segments.filter { segment in
            if isValidSegmentFile(segment.url) { return true }
            if protected.contains(segment.url) { return true }
            logRecorder("Dropping stale segment ref: \(segment.url.lastPathComponent) size=\(fileSize(at: segment.url))")
            return false
        }
        if segments.count != before {
            logRecorder("Purged \(before - segments.count) stale segment ref(s)")
        }
    }

    private func updateBufferState() {
        purgeStaleSegments()
        let validSegments = segments.filter { isValidSegmentFile($0.url) }
        let finalized = validSegments.reduce(0) { $0 + $1.duration }
        let inProgress: TimeInterval
        if let writer = segmentWriter, writer.currentSegmentURL != nil {
            inProgress = min(segmentDuration, Double(writer.writtenFrameCount) / Double(activeCaptureFPS))
        } else {
            inProgress = 0
        }
        bufferedSeconds = min(maxBufferDuration, finalized + inProgress)
        segmentCount = validSegments.count
        isBufferReady = finalized >= 3 || (validSegments.count >= 1 && finalized >= segmentDuration - 0.5)

        if isCapturing {
            if isBufferReady {
                statusMessage = "Ready · \(Int(bufferedSeconds))s buffered"
            } else {
                statusMessage = "Buffering… \(Int(bufferedSeconds))s"
            }
        }
    }

    private func pruneSegments() {
        guard !isClipping else { return }
        purgeStaleSegments()
        guard let newest = segments.last else { return }
        segments = segments.filter { newest.startTime.timeIntervalSince($0.startTime) < maxBufferDuration }
        let protected = protectedSegmentURLs()
        let keep = Set(segments.map(\.url)).union(protected)
        if let files = try? FileManager.default.contentsOfDirectory(at: bufferDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                let name = file.lastPathComponent
                let isSegment = name.hasPrefix("seg_") && (file.pathExtension == "mov" || file.pathExtension == "mp4")
                let isExportStaging = name.hasPrefix("export_")
                let isSidecar = name.contains(".sb-")
                if isSidecar || isExportStaging {
                    continue
                }
                if isSegment && !keep.contains(file) {
                    logRecorder("Pruning old segment file: \(name)")
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        updateBufferState()
    }
}

extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            ClippyDebugLog.shared.logError("Recorder", error, context: "SCStream stopped")
            isCapturing = false
            statusMessage = "Capture stopped — check Screen Recording permission for Clippy"
            isBufferReady = segments.contains { isValidSegmentFile($0.url) }
        }
    }
}

extension ScreenRecorder: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        processingQueue.async { [weak self] in
            switch type {
            case .screen:
                self?.segmentWriter?.processVideo(sampleBuffer)
            case .audio:
                self?.segmentWriter?.processSystemAudio(sampleBuffer)
            case .microphone:
                self?.segmentWriter?.processMicrophoneAudio(sampleBuffer)
            @unknown default:
                break
            }
        }
    }
}

import AppKit
