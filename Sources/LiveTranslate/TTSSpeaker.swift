import Foundation
import AVFoundation

/// Synthesizes translation text into 24 kHz mono PCM16 LE buffers and
/// hands each chunk to a callback (typically `LiveAudioServer.append`).
/// Never plays through the local speakers — uses
/// `AVSpeechSynthesizer.write(_:toBufferCallback:)`, which delivers
/// raw `AVAudioPCMBuffer`s without engaging an output device.
///
/// Serial queue: one utterance plays end-to-end before the next
/// starts, so listeners hear sentences in order, not overlapping.
/// Backpressure: if more than `maxQueue` sentences are pending the
/// **oldest** are dropped — a listener tolerates skipped lines better
/// than ever-growing lag.
///
/// Voice selection: see `bestVoice(forTargetCode:)`. Caller checks
/// availability before instantiating and skips the whole stream
/// feature if no voice is installed for the target language.
final class TTSSpeaker: @unchecked Sendable {

    /// Pick the highest-quality installed voice whose language matches
    /// the given target code's primary subtag. `code` may be a plain
    /// language code (`"en"`) or a regional / script tag
    /// (`"en-US"`, `"zh-Hans"`); we match on the primary subtag so a
    /// `zh-Hans` target accepts any Chinese voice the user has
    /// installed (Apple ships them as `zh-CN`, `zh-TW`, etc.).
    ///
    /// Returns nil when no installed voice matches. The caller is
    /// expected to skip the TTS stream entirely in that case rather
    /// than fall back to a wrong-language voice.
    ///
    /// Quality order: `.premium > .enhanced > .default`. Premium /
    /// Enhanced voices ship as on-demand downloads (System Settings
    /// → Accessibility → Spoken Content → System Voice); the README
    /// nudges the user to install one before relying on this.
    static func bestVoice(forTargetCode code: String) -> AVSpeechSynthesisVoice? {
        let primary = String(code.split(separator: "-").first ?? Substring(code))
        let matching = AVSpeechSynthesisVoice.speechVoices().filter { v in
            v.language == code
                || v.language == primary
                || v.language.hasPrefix(primary + "-")
        }
        if matching.isEmpty { return nil }
        let rank: (AVSpeechSynthesisVoice) -> Int = { v in
            switch v.quality {
            case .premium:  return 3
            case .enhanced: return 2
            default:        return 1
            }
        }
        return matching.max { rank($0) < rank($1) }
    }

    /// 1.0 = AVSpeechUtteranceDefaultSpeechRate (~175 wpm).
    static let speechRate: Float = AVSpeechUtteranceDefaultSpeechRate * 1.05

    private let voice: AVSpeechSynthesisVoice
    private let onPCM: (Data) -> Void
    private let onActivityChanged: (Bool) -> Void
    private let q = DispatchQueue(label: "TTSSpeaker.queue")
    private var pending: [String] = []
    private var busy: Bool = false
    private let synth = AVSpeechSynthesizer()
    private let maxQueue = 5

    private let outFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24000,
            channels: 1,
            interleaved: true
        )!
    }()

    init(voice: AVSpeechSynthesisVoice,
         onPCM: @escaping (Data) -> Void,
         onActivityChanged: @escaping (Bool) -> Void = { _ in }) {
        self.voice = voice
        self.onPCM = onPCM
        self.onActivityChanged = onActivityChanged
        Log.line("TTSSpeaker: voice=\(voice.name) [\(voice.language)] quality=\(qualityLabel(voice.quality))")
        // Pre-warm: synthesize a silent utterance now so the voice model
        // is loaded before the first real sentence arrives.
        q.async { [synth, voice] in
            let utt = AVSpeechUtterance(string: " ")
            utt.voice = voice
            synth.write(utt) { _ in }
        }
    }

    /// Drop pending utterances. Currently-speaking one finishes
    /// (`AVSpeechSynthesizer.write` is not interruptible mid-buffer).
    func stop() {
        q.async { [weak self] in
            self?.pending.removeAll()
        }
    }

    /// Append a sentence's translation to the speak queue. Empty /
    /// whitespace-only strings are dropped. Returns immediately.
    func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        q.async { [weak self] in
            guard let self else { return }
            self.pending.append(trimmed)
            if self.pending.count > self.maxQueue {
                // Drop oldest — listener tolerates gaps better than growing lag.
                let drop = self.pending.count - self.maxQueue
                self.pending.removeFirst(drop)
            }
            self.pumpLocked()
        }
    }

    // MARK: - Internals — `q`-isolated

    private func pumpLocked() {
        // Signal idle only now — keeps speakingActive=true through the
        // 0.5 s drain gap so the heartbeat can't inject silence while
        // the client is still consuming buffered audio.
        if !busy { onActivityChanged(false) }
        guard !busy, !pending.isEmpty else { return }
        let text = pending.removeFirst()
        busy = true
        speak(text) { [weak self] in
            // 0.5 s gap: client has time to consume the last utterance's
            // buffered audio before the next one starts.
            self?.q.asyncAfter(deadline: .now() + 0.5) {
                self?.busy = false
                self?.pumpLocked()
            }
        }
    }

    /// Drive one utterance through `AVSpeechSynthesizer.write`,
    /// converting each delivered `AVAudioPCMBuffer` to 24 kHz mono
    /// PCM16 LE and forwarding to `onPCM`. The callback may fire many
    /// times during synthesis; the run terminates with a zero-frame
    /// buffer — that's when we call `done()`.
    ///
    /// One `AVAudioConverter` per utterance: sample-rate converters
    /// carry resampling state and must see input as a continuous
    /// stream. We feed each delivered buffer through with
    /// `.haveData` once, then `.noDataNow` so the converter outputs
    /// what it can without claiming end-of-stream.
    private func speak(_ text: String, done: @escaping () -> Void) {
        let utt = AVSpeechUtterance(string: text)
        utt.voice = voice
        utt.rate = Self.speechRate

        var converter: AVAudioConverter?
        var finished = false
        let finishLock = NSLock()

        let outFmt = self.outFormat
        let emit = self.onPCM

        onActivityChanged(true)
        synth.write(utt) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }

            if pcm.frameLength == 0 {
                // End-of-utterance sentinel from AVSpeechSynthesizer.
                // Try one flush in case the resampler held a tail.
                if let conv = converter {
                    if let flushed = Self.flush(conv, outFormat: outFmt) {
                        emit(flushed)
                    }
                }
                finishLock.lock()
                let already = finished
                finished = true
                finishLock.unlock()
                if !already { done() }
                return
            }

            if converter == nil {
                converter = AVAudioConverter(from: pcm.format, to: outFmt)
                if converter == nil {
                    Log.line("TTSSpeaker: AVAudioConverter init failed (in=\(pcm.format), out=\(outFmt))")
                }
            }
            guard let conv = converter else { return }

            if let data = Self.convert(pcm: pcm, with: conv, outFormat: outFmt) {
                emit(data)
            }
        }
    }

    private static func convert(
        pcm: AVAudioPCMBuffer,
        with conv: AVAudioConverter,
        outFormat: AVAudioFormat
    ) -> Data? {
        // Cap output buffer size at ceil(inFrames * outRate / inRate) plus
        // a slack of 1024 frames for the resampler's internal latency.
        let ratio = outFormat.sampleRate / pcm.format.sampleRate
        let outCap = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else { return nil }

        var supplied = false
        var err: NSError?
        let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
            if supplied {
                // Out of input for this call. `.noDataNow` tells the
                // converter to return what it has without claiming
                // end-of-stream — so its resampler state persists for
                // the next buffer in the utterance.
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return pcm
        }
        if status == .error {
            Log.line("TTSSpeaker: convert error \(err?.localizedDescription ?? "?")")
            return nil
        }
        return Self.dataFromInt16(outBuf)
    }

    private static func flush(_ conv: AVAudioConverter, outFormat: AVAudioFormat) -> Data? {
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 4096) else { return nil }
        var err: NSError?
        let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        if status == .error { return nil }
        return dataFromInt16(outBuf)
    }

    private static func dataFromInt16(_ buf: AVAudioPCMBuffer) -> Data? {
        guard buf.frameLength > 0, let ch = buf.int16ChannelData?[0] else { return nil }
        let byteCount = Int(buf.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: ch, count: byteCount)
    }
}

private func qualityLabel(_ q: AVSpeechSynthesisVoiceQuality) -> String {
    switch q {
    case .premium:  return "Premium"
    case .enhanced: return "Enhanced"
    default:        return "Default"
    }
}
