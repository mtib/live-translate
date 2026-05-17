import Foundation
import Network

/// Tiny HTTP/1.1 server that streams an open-ended WAV to any client
/// that connects. Designed for a *single* purpose: serve the queue of
/// synthesized translation audio coming out of `TTSSpeaker` over the
/// LAN so a phone-with-headphones can listen along.
///
/// Why hand-rolled and not Vapor / HLS / RTSP?
///   - HLS adds 6–30 s of segmenting latency, defeats "semi-real-time".
///   - WebRTC needs signaling, way out of scope.
///   - Icecast / shoutcast are external server processes.
///   - HTTP/1.1 with a Content-Length-free, max-size-marker WAV body
///     is universally understood: VLC, mpv, ffplay, iOS Safari
///     `<audio>`, Chrome, QuickTime (the last buffers heavily — warn).
///
/// Wire format: **24 kHz mono PCM16 LE.** Matches what `TTSSpeaker`
/// emits after its `AVAudioConverter` pass. Header advertises a
/// data chunk size of `0xFFFFFFFF` — most players read this as
/// "stream until socket close." `Connection: close`, no Content-Length.
///
/// Keep-alive: a 200 ms heartbeat task watches the last-real-send
/// timestamp. If nothing has been pushed in the last 100 ms it
/// broadcasts 50 ms of silence (2400 bytes). VLC drops the socket
/// after ~5 s of idle otherwise.
///
/// Sender bookkeeping: subscribers are tracked by UUID in a
/// `NSLock`-guarded dictionary. The listener and per-connection
/// callbacks all execute on a single serial DispatchQueue, but the
/// public `append(_:)` is callable from anywhere — hence the lock.
final class LiveAudioServer: @unchecked Sendable {

    let port: UInt16

    private let queue = DispatchQueue(label: "LiveAudioServer")
    private var listener: NWListener?
    private var subscribers: [UUID: NWConnection] = [:]
    private let lock = NSLock()
    private var heartbeatTask: Task<Void, Never>?
    private var lastSendAt: Date = .distantPast
    private var speakingActive: Bool = false

    /// Called by TTSSpeaker at utterance start/end so the heartbeat
    /// won't inject silence into the middle of real speech.
    func setSpeaking(_ active: Bool) {
        lock.lock()
        speakingActive = active
        if active { lastSendAt = Date() }
        lock.unlock()
    }

    init(port: UInt16) {
        self.port = port
    }

    /// Start listening. Throws if the port is in use.
    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        l.stateUpdateHandler = { state in
            switch state {
            case .failed(let err):
                Log.line("LiveAudioServer: listener failed: \(err.localizedDescription)")
            default: break
            }
        }
        l.start(queue: queue)
        listener = l
        startHeartbeat()
        Log.line("LiveAudioServer: listening on :\(port)")
    }

    /// Tear down. Closes every subscriber socket, cancels listener,
    /// stops the heartbeat. Idempotent.
    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        lock.lock()
        let conns = Array(subscribers.values)
        subscribers.removeAll()
        lock.unlock()
        for c in conns { c.cancel() }
        listener?.cancel()
        listener = nil
    }

    /// Push a chunk of 24 kHz mono PCM16 LE audio to every subscriber.
    /// Safe to call from any thread.
    func append(_ pcm16: Data) {
        broadcast(pcm16)
        lastSendAt = Date()
    }

    // MARK: - Internals

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        // We don't actually care what the client requested — any GET
        // gets the stream. Drain the request line before responding so
        // some HTTP clients don't trip on a half-duplex socket.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] _, _, _, _ in
            guard let self else { return }
            let headers = "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nCache-Control: no-cache, no-store\r\nConnection: close\r\n\r\n".data(using: .utf8)!
            var preamble = headers
            preamble.append(Self.streamingWavHeader())
            conn.send(content: preamble, completion: .contentProcessed { [weak self] err in
                guard let self else { return }
                if err != nil { conn.cancel(); return }
                let id = UUID()
                self.lock.lock()
                self.subscribers[id] = conn
                self.lock.unlock()
                Log.line("LiveAudioServer: subscriber +1 (id=\(id.uuidString.prefix(8)))")
                conn.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .cancelled, .failed:
                        self?.lock.lock()
                        self?.subscribers.removeValue(forKey: id)
                        self?.lock.unlock()
                    default: break
                    }
                }
            })
        }
    }

    private func broadcast(_ data: Data) {
        lock.lock()
        let conns = Array(subscribers.values)
        lock.unlock()
        guard !conns.isEmpty else { return }
        for c in conns {
            c.send(content: data, completion: .contentProcessed { err in
                if err != nil { c.cancel() }
            })
        }
    }

    private func startHeartbeat() {
        // Every 200 ms, if nothing real has been broadcast in the last
        // 100 ms, push 50 ms of silence at 24 kHz Int16 mono =
        // 1200 samples = 2400 bytes. Empirically VLC tears the socket
        // down after ~5 s of no bytes; mpv tolerates more but no point
        // tuning per-client.
        heartbeatTask = Task { [weak self] in
            let silence = Data(count: 2400)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                self.lock.lock()
                let speaking = self.speakingActive
                self.lock.unlock()
                if !speaking && Date().timeIntervalSince(self.lastSendAt) >= 0.1 {
                    self.broadcast(silence)
                    self.lastSendAt = Date()
                }
            }
        }
    }

    // MARK: - WAV header

    /// 44-byte RIFF/WAV header advertising 24 kHz mono PCM16 LE with a
    /// data-chunk size of `0xFFFFFFFF` ("read until close"). VLC, mpv,
    /// ffmpeg, iOS Safari all interpret max-uint32 as "open-ended".
    static func streamingWavHeader() -> Data {
        var d = Data(capacity: 44)
        d.append(contentsOf: "RIFF".utf8)
        d.append(u32(0xFFFFFFFF))         // RIFF chunk size (unknown)
        d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8)
        d.append(u32(16))                 // fmt subchunk size
        d.append(u16(1))                  // PCM
        d.append(u16(1))                  // channels
        d.append(u32(24000))              // sample rate
        d.append(u32(24000 * 2))          // byte rate
        d.append(u16(2))                  // block align
        d.append(u16(16))                 // bits per sample
        d.append(contentsOf: "data".utf8)
        d.append(u32(0xFFFFFFFF))         // data chunk size (unknown)
        return d
    }

    private static func u32(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
    }
    private static func u16(_ v: UInt16) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 2)
    }

    // MARK: - URL helpers

    /// `http://<machine>.local:<port>/` — the form that resolves on
    /// iOS, Android, and Windows without typing the numeric IP.
    /// macOS hands us "machine.local" via `ProcessInfo.hostName`.
    /// Falls back to "localhost" if the host name is empty.
    ///
    /// We deliberately do NOT use `ProcessInfo.hostName`: that returns
    /// whatever the kernel hostname is set to, which on a Mac
    /// connected to a corporate VPN becomes the VPN-assigned name
    /// (e.g. `mtib-m1.vpn.mm`) — a hostname that only resolves inside
    /// that VPN, not on the LAN where the user's phone is. Instead we
    /// pull `LocalHostName` from `scutil` and append `.local` — that's
    /// the canonical Bonjour name the Mac advertises and what mDNS
    /// clients resolve. Falls back to the first private-range IPv4 if
    /// the dynamic store call fails, and finally to `localhost`.
    static func streamURL(port: UInt16) -> String {
        if let ip = firstPrivateIPv4() {
            return "http://\(ip):\(port)/"
        }
        if let h = scutilLocalHostName(), !h.isEmpty {
            return "http://\(h).local:\(port)/"
        }
        return "http://localhost:\(port)/"
    }

    /// Read the SystemConfiguration dynamic store's `LocalHostName`
    /// (e.g. `mtib-m1`) — the same value `scutil --get LocalHostName`
    /// returns. macOS uses it for Bonjour advertising regardless of
    /// what the VPN does to the kernel hostname, so
    /// `<LocalHostName>.local` is the stable LAN-resolvable name.
    private static func scutilLocalHostName() -> String? {
        let task = Process()
        task.launchPath = "/usr/sbin/scutil"
        task.arguments = ["--get", "LocalHostName"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty == false) ? s : nil
        } catch {
            return nil
        }
    }

    /// Walk `getifaddrs` for the first non-loopback IPv4 in the
    /// RFC 1918 private ranges (10/8, 172.16/12, 192.168/16). Skips
    /// VPN tun/utun interfaces so we still return the LAN address.
    private static func firstPrivateIPv4() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard let addr = p.pointee.ifa_addr,
                  (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("tun") {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                 &host, socklen_t(host.count),
                                 nil, 0, NI_NUMERICHOST)
            if rc == 0 {
                let ip = String(cString: host)
                if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") {
                    return ip
                }
                // 172.16.0.0/12: 172.16. through 172.31.
                if ip.hasPrefix("172.") {
                    let parts = ip.split(separator: ".")
                    if parts.count == 4, let second = Int(parts[1]),
                       (16...31).contains(second) {
                        return ip
                    }
                }
            }
        }
        return nil
    }
}
