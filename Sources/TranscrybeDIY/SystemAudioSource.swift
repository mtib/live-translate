import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Captures audio playing through the system speakers (or per-app audio,
/// once we expose that toggle) via `ScreenCaptureKit`. This bypasses the
/// speaker → microphone round-trip, which is what was making the
/// MicrophoneSource stall when you tried to transcribe video/music output:
/// the recognizer was seeing the room mic mixed with the speaker bleed and
/// either getting "no speech detected" or producing garbage.
///
/// Requirements:
///   - macOS 13+ (we target 15).
///   - **Screen Recording permission** in System Settings → Privacy &
///     Security → Screen Recording. macOS prompts on first start. Without
///     it, `startCapture()` throws.
///
/// `ScreenCaptureKit` is screen-capture-first, but it can run audio-only:
/// we just never read the video samples.
final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "SystemAudioSource.samples", qos: .userInteractive)

    /// Broadcaster — see MicrophoneSource for the same pattern. We have to
    /// re-emit to multiple subscribers because the AsyncStream returned by
    /// `buffers` is single-consumer.
    private var listeners: [UUID: AsyncStream<AVAudioPCMBuffer>.Continuation] = [:]
    private let listenerLock = NSLock()

    var buffers: AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { cont in
            let id = UUID()
            self.listenerLock.lock()
            self.listeners[id] = cont
            self.listenerLock.unlock()
            cont.onTermination = { [weak self] _ in
                self?.listenerLock.lock()
                self?.listeners.removeValue(forKey: id)
                self?.listenerLock.unlock()
            }
        }
    }

    /// AVAudioConverter to coerce whatever SCK gives us into the 16 kHz mono
    /// Float32 format that Apple Speech expects. Built lazily because we
    /// don't know the source format until the first sample arrives.
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    /// Async start — see the AudioSource protocol comment. Doing this sync
    /// with a semaphore deadlocks the MainActor (the async hop has nowhere
    /// to run because the main thread is blocked waiting on the semaphore).
    func start() async throws {
        // 1. Shareable content. The "display" is what we attach the audio
        //    filter to; we exclude no apps so all system audio is captured.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        // 2. Stream config — audio only. We can't disable video entirely, but
        //    we can keep it tiny and ignore the buffers.
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true        // don't loop our own UI sounds
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        // Minimum-cost video so SCK is happy. We don't subscribe to .screen samples.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        Log.line("SystemAudio: capture started")
    }

    func stop() {
        guard let stream else { return }
        Task {
            do { try await stream.stopCapture() }
            catch { Log.line("SystemAudio: stopCapture error: \(error)") }
        }
        self.stream = nil
        Log.line("SystemAudio: capture stopped")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer)
        else { return }
        guard let pcm = makePCMBuffer(from: sampleBuffer) else { return }

        listenerLock.lock()
        let conts = Array(listeners.values)
        listenerLock.unlock()
        for c in conts { c.yield(pcm) }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.line("SystemAudio: stream stopped with error: \(error.localizedDescription)")
    }

    // MARK: - Sample conversion

    /// Convert a CMSampleBuffer (from SCK) into the AVAudioPCMBuffer format
    /// Apple Speech expects (16 kHz mono Float32, non-interleaved).
    private func makePCMBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = sample.formatDescription,
              let asbd = formatDesc.audioStreamBasicDescription else { return nil }

        // (Re)build the converter when the source format changes.
        if converter == nil || sourceFormat?.sampleRate != asbd.mSampleRate
            || sourceFormat?.channelCount != AVAudioChannelCount(asbd.mChannelsPerFrame) {
            var asbdCopy = asbd
            guard let src = AVAudioFormat(streamDescription: &asbdCopy) else { return nil }
            self.sourceFormat = src
            self.converter = AVAudioConverter(from: src, to: targetFormat)
        }
        guard let converter, let sourceFormat else { return nil }

        // Pull the data out as an AVAudioPCMBuffer.
        guard let srcBuffer = AVAudioPCMBuffer.fromCMSampleBuffer(sample, format: sourceFormat) else {
            return nil
        }

        let targetCapacity = AVAudioFrameCount(
            Double(srcBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate
        ) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            return nil
        }

        var didFeed = false
        let status = converter.convert(to: outBuffer, error: nil) { _, outStatus in
            if didFeed { outStatus.pointee = .noDataNow; return nil }
            didFeed = true
            outStatus.pointee = .haveData
            return srcBuffer
        }
        if status == .error { return nil }
        return outBuffer
    }
}

enum SystemAudioError: LocalizedError {
    case noDisplay
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display available for ScreenCaptureKit."
        }
    }
}

// MARK: - Helpers

private extension AudioStreamBasicDescription {
    func copy() -> AudioStreamBasicDescription { self }
}

private extension AVAudioPCMBuffer {
    /// Build an AVAudioPCMBuffer that shares the data of a CMSampleBuffer.
    /// We copy into a fresh buffer so the lifetime is independent of the
    /// CMSampleBuffer (which CoreMedia may reclaim once we return).
    static func fromCMSampleBuffer(_ sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let numSamples = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard numSamples > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: numSamples)
        else { return nil }
        buffer.frameLength = numSamples

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        // Copy raw bytes into the destination buffer's channel data.
        // We assume the source's mBuffers[0] holds all interleaved channel data
        // matching `format`; AVAudioConverter will handle the actual layout.
        let src = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        guard let firstBuf = src.first,
              let destBuf = buffer.audioBufferList.pointee.mBuffers.mData,
              let srcData = firstBuf.mData else { return buffer }
        let copyBytes = Int(min(firstBuf.mDataByteSize, buffer.audioBufferList.pointee.mBuffers.mDataByteSize))
        memcpy(destBuf, srcData, copyBytes)
        return buffer
    }
}
