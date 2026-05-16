import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Captures audio playing through the system speakers via
/// `ScreenCaptureKit`. Bypasses the speaker→mic round-trip, which was the
/// cause of MicrophoneSource stalling on video/music playback: the
/// recognizer was seeing mic + speaker bleed and either getting
/// "no speech detected" or producing garbage.
///
/// Requirements:
///   - macOS 13+ (we target 15).
///   - **Screen Recording permission** in System Settings → Privacy &
///     Security → Screen Recording. macOS prompts on first start.
///
/// `ScreenCaptureKit` is screen-capture-first but supports audio-only
/// configurations: we just never subscribe to `.screen` samples.
final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "SystemAudioSource.samples", qos: .userInteractive)

    private var listeners: [UUID: AsyncStream<AVAudioPCMBuffer>.Continuation] = [:]
    private let lock = NSLock()

    /// Diagnostic counters logged once per second so we can verify the
    /// system-audio path is actually delivering samples — silent failure
    /// here is otherwise hard to spot.
    private var diag = Diag()
    private struct Diag {
        var samplesReceived: Int = 0
        var samplesYielded: Int = 0
        var conversionFailures: Int = 0
        var lastLog: Date = .distantPast
        var loggedFormat: Bool = false
    }

    var buffers: AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { cont in
            let id = UUID()
            self.lock.withLock { self.listeners[id] = cont }
            cont.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.listeners.removeValue(forKey: id) }
            }
        }
    }

    /// Lazy-built converter to coerce SCK's source format into the 16 kHz
    /// mono Float32 that SFSpeech (and a future whisper backend) accept.
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    /// SCK setup is natively async — do not fake a sync wrapper around it.
    /// (Earlier we did, with a `DispatchSemaphore`, and deadlocked the
    /// MainActor. See CLAUDE.md "Things that have bitten us" #9.)
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw SystemAudioError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        // SCK requires *some* video config; we keep it tiny and ignore the samples.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        Log.line("SystemAudio: capture started")
    }

    /// Async so the caller can `await` the SCK teardown — without this,
    /// rapid Stop→Start cycles could race the new stream against the
    /// not-yet-stopped previous one.
    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do { try await stream.stopCapture() }
        catch { Log.line("SystemAudio: stopCapture error: \(error)") }
        Log.line("SystemAudio: capture stopped")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer)
        else { return }
        diag.samplesReceived += 1

        // Log the actual source format once — helps debug "why is nothing
        // being transcribed". Often the recognizer is fine; we're just
        // sending it the wrong format or silence.
        if !diag.loggedFormat,
           let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription {
            Log.line("SystemAudio: source ASBD sr=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) flags=\(asbd.mFormatFlags)")
            diag.loggedFormat = true
        }

        guard let pcm = makePCMBuffer(from: sampleBuffer) else {
            diag.conversionFailures += 1
            heartbeatIfDue()
            return
        }
        diag.samplesYielded += 1
        heartbeatIfDue()

        let conts = lock.withLock { Array(listeners.values) }
        for c in conts { c.yield(pcm) }
    }

    /// Once per second, dump throughput counters so we can spot silent
    /// failures (samples received but never yielded, or never received at
    /// all — both common with ScreenCaptureKit misconfiguration).
    private func heartbeatIfDue() {
        let now = Date()
        guard now.timeIntervalSince(diag.lastLog) >= 1.0 else { return }
        Log.line("SystemAudio: heartbeat received=\(diag.samplesReceived) yielded=\(diag.samplesYielded) convFails=\(diag.conversionFailures) listeners=\(lock.withLock { listeners.count })")
        diag.lastLog = now
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.line("SystemAudio: stream stopped with error: \(error.localizedDescription)")
    }

    // MARK: - Sample conversion

    /// Convert one `CMSampleBuffer` from SCK into a 16 kHz mono Float32
    /// `AVAudioPCMBuffer`. The source format is whatever SCK chose
    /// (typically 48 kHz stereo Float32); we use `AVAudioConverter` to
    /// downsample + downmix.
    private func makePCMBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = sample.formatDescription,
              let asbd = formatDesc.audioStreamBasicDescription else { return nil }

        // Rebuild the converter when the source format changes (rare —
        // typically just once at the start of the stream).
        if converter == nil
            || sourceFormat?.sampleRate != asbd.mSampleRate
            || sourceFormat?.channelCount != AVAudioChannelCount(asbd.mChannelsPerFrame) {
            var asbdCopy = asbd
            guard let src = AVAudioFormat(streamDescription: &asbdCopy) else { return nil }
            self.sourceFormat = src
            self.converter = AVAudioConverter(from: src, to: targetFormat)
        }
        guard let converter, let sourceFormat else { return nil }

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
        return status == .error ? nil : outBuffer
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

private extension AVAudioPCMBuffer {
    /// Build an `AVAudioPCMBuffer` from a `CMSampleBuffer`, copying the
    /// sample data so the buffer's lifetime is independent of CoreMedia.
    ///
    /// Uses `CMSampleBufferCopyPCMDataIntoAudioBufferList`, which writes
    /// straight into the destination's `mutableAudioBufferList`. This
    /// matters because `mutableAudioBufferList` is sized correctly for
    /// the destination's format (e.g. 2 separate buffers for
    /// non-interleaved stereo). The previous implementation used
    /// `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` with a
    /// fixed-size `AudioBufferList`, which only fits **one** AudioBuffer
    /// slot — so non-interleaved stereo sources (which is what
    /// ScreenCaptureKit actually delivers) failed every sample with
    /// `kCMSampleBufferError_ArrayTooSmall`.
    static func fromCMSampleBuffer(_ sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let numSamples = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard numSamples > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: numSamples)
        else { return nil }
        buffer.frameLength = numSamples

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample,
            at: 0,
            frameCount: Int32(numSamples),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
