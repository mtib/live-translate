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
    /// Clients consuming the WAV stream (browsers' `<audio>`, VLC, mpv, …).
    private var audioSubscribers: [UUID: NWConnection] = [:]
    /// Clients consuming the SSE transcript stream (the listen page).
    private var eventSubscribers: [UUID: NWConnection] = [:]
    /// Replay buffer for SSE — every finalized sentence as a JSONL line.
    /// Capped at 200 entries so very long sessions don't grow unbounded.
    private var eventReplay: [String] = []
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

    /// How many clients are currently connected to `/live.wav`. Lets
    /// the pipeline skip TTS synthesis (and the speaker lazy-load the
    /// model) when there's nobody to listen.
    var audioListenerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return audioSubscribers.count
    }

    /// Fired whenever the `/live.wav` subscriber count changes. The
    /// pipeline uses this to drive the "TTS active" UI indicator and
    /// could in principle gate other listener-aware optimizations.
    /// Called off the main thread; hop to MainActor before touching
    /// `@Published` state.
    var onAudioListenerCountChanged: (@Sendable (Int) -> Void)?

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
        let audio = Array(audioSubscribers.values)
        let events = Array(eventSubscribers.values)
        audioSubscribers.removeAll()
        eventSubscribers.removeAll()
        eventReplay.removeAll()
        lock.unlock()
        for c in audio { c.cancel() }
        for c in events { c.cancel() }
        listener?.cancel()
        listener = nil
    }

    /// Push a chunk of 24 kHz mono PCM16 LE audio to every subscriber.
    /// Safe to call from any thread.
    func append(_ pcm16: Data) {
        broadcastAudio(pcm16)
        lastSendAt = Date()
    }

    /// Push one finalized-sentence JSONL line (same shape as the on-disk
    /// transcript) to every SSE subscriber, and buffer it so future
    /// subscribers can replay the session so far. Safe to call from
    /// any thread.
    func publishTranscript(jsonLine: String) {
        let event = "data: \(jsonLine)\n\n".data(using: .utf8) ?? Data()
        lock.lock()
        eventReplay.append(jsonLine)
        if eventReplay.count > 200 {
            eventReplay.removeFirst(eventReplay.count - 200)
        }
        let conns = Array(eventSubscribers.values)
        lock.unlock()
        for c in conns {
            c.send(content: event, completion: .contentProcessed { err in
                if err != nil { c.cancel() }
            })
        }
    }

    // MARK: - Internals

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else {
                conn.cancel(); return
            }
            let path = Self.requestPath(req)
            switch path {
            case "/":              self.serveListenPage(conn)
            case "/live.wav":      self.serveAudioStream(conn)
            case "/events":        self.serveEventStream(conn)
            default:               self.serveNotFound(conn)
            }
        }
    }

    /// Extract the request-target from the HTTP request line. Returns
    /// "/" if the request can't be parsed (mostly defensive).
    private static func requestPath(_ raw: String) -> String {
        guard let firstLine = raw.split(separator: "\r\n", maxSplits: 1).first else { return "/" }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        // Strip query string if any so `/live.wav?t=123` still routes.
        let target = String(parts[1])
        return target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    }

    private func serveListenPage(_ conn: NWConnection) {
        let body = Self.listenPageHTML.data(using: .utf8) ?? Data()
        var resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache, no-store\r\nConnection: close\r\n\r\n".data(using: .utf8)!
        resp.append(body)
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func serveAudioStream(_ conn: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nCache-Control: no-cache, no-store\r\nConnection: close\r\n\r\n".data(using: .utf8)!
        var preamble = headers
        preamble.append(Self.streamingWavHeader())
        conn.send(content: preamble, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            if err != nil { conn.cancel(); return }
            let id = UUID()
            self.lock.lock()
            self.audioSubscribers[id] = conn
            let newCount = self.audioSubscribers.count
            self.lock.unlock()
            Log.line("LiveAudioServer: audio subscriber +1 (id=\(id.uuidString.prefix(8)))")
            self.onAudioListenerCountChanged?(newCount)
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .cancelled, .failed:
                    guard let self else { return }
                    self.lock.lock()
                    self.audioSubscribers.removeValue(forKey: id)
                    let count = self.audioSubscribers.count
                    self.lock.unlock()
                    self.onAudioListenerCountChanged?(count)
                default: break
                }
            }
        })
    }

    private func serveEventStream(_ conn: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache, no-store\r\nConnection: close\r\n\r\n".data(using: .utf8)!
        // Replay buffered events so a late subscriber sees the session so far.
        lock.lock()
        let replay = eventReplay
        lock.unlock()
        var preamble = headers
        for line in replay {
            preamble.append("data: \(line)\n\n".data(using: .utf8) ?? Data())
        }
        // Initial comment line — some proxies need a flush before the
        // first real event for the connection to be considered "live".
        preamble.append(": ready\n\n".data(using: .utf8) ?? Data())
        conn.send(content: preamble, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            if err != nil { conn.cancel(); return }
            let id = UUID()
            self.lock.lock()
            self.eventSubscribers[id] = conn
            self.lock.unlock()
            Log.line("LiveAudioServer: events subscriber +1 (id=\(id.uuidString.prefix(8)))")
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .cancelled, .failed:
                    self?.lock.lock()
                    self?.eventSubscribers.removeValue(forKey: id)
                    self?.lock.unlock()
                default: break
                }
            }
        })
    }

    private func serveNotFound(_ conn: NWConnection) {
        let body = "404 Not Found\n".data(using: .utf8) ?? Data()
        var resp = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".data(using: .utf8)!
        resp.append(body)
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func broadcastAudio(_ data: Data) {
        lock.lock()
        let conns = Array(audioSubscribers.values)
        lock.unlock()
        guard !conns.isEmpty else { return }
        for c in conns {
            c.send(content: data, completion: .contentProcessed { err in
                if err != nil { c.cancel() }
            })
        }
    }

    private func startHeartbeat() {
        // Audio heartbeat: every 200 ms, if nothing real has been
        // broadcast in the last 100 ms, push 50 ms of silence at
        // 24 kHz Int16 mono = 1200 samples = 2400 bytes. VLC tears
        // the socket down after ~5 s of no bytes; mpv tolerates more
        // but no point tuning per-client.
        //
        // SSE heartbeat: every 5 s, send a `: ping` comment line on
        // each event-stream subscriber. Mobile carriers and NAT
        // routers drop idle TCP connections, and SSE has no built-in
        // keepalive — the comment line keeps the socket warm without
        // emitting a real event the client would dispatch.
        heartbeatTask = Task { [weak self] in
            let silence = Data(count: 2400)
            let sseHeartbeat = ": ping\n\n".data(using: .utf8) ?? Data()
            var sseTick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                self.lock.lock()
                let speaking = self.speakingActive
                self.lock.unlock()
                if !speaking && Date().timeIntervalSince(self.lastSendAt) >= 0.1 {
                    self.broadcastAudio(silence)
                    self.lastSendAt = Date()
                }
                // 5 s SSE heartbeat = 25 × 200 ms ticks.
                sseTick += 1
                if sseTick >= 25 {
                    sseTick = 0
                    self.lock.lock()
                    let evConns = Array(self.eventSubscribers.values)
                    self.lock.unlock()
                    for c in evConns {
                        c.send(content: sseHeartbeat, completion: .contentProcessed { err in
                            if err != nil { c.cancel() }
                        })
                    }
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

    // MARK: - Listen page (self-contained HTML/CSS/JS)

    /// The single-file listen page served at `/`. Audio via `<audio>`
    /// on `/live.wav`; finalized sentences arrive via SSE on `/events`
    /// (one JSONL line per packet, same shape as the on-disk
    /// transcript). The page auto-resyncs when audio falls behind,
    /// reconnects on the SSE channel if the connection drops, and
    /// renders the transcript as it streams in.
    private static let listenPageHTML: String = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="theme-color" content="#0a0a0a">
    <title>LiveTranslate</title>
    <style>
    :root { color-scheme: dark; }
    * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
    html, body {
      margin: 0; padding: 0;
      background: #0a0a0a; color: #f0f0f0;
      font: 15px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      min-height: 100vh; min-height: 100dvh;
    }
    body {
      display: flex; flex-direction: column;
      padding-top: env(safe-area-inset-top);
      padding-bottom: env(safe-area-inset-bottom);
    }
    header {
      position: sticky; top: 0;
      background: rgba(10,10,10,0.92);
      backdrop-filter: saturate(180%) blur(12px);
      -webkit-backdrop-filter: saturate(180%) blur(12px);
      padding: 14px 16px;
      border-bottom: 1px solid #1f1f1f;
      display: flex; align-items: center; gap: 14px;
      z-index: 10;
    }
    #play {
      flex: 0 0 auto;
      min-width: 110px; height: 44px;
      border-radius: 22px;
      border: 1.5px solid #f0f0f0;
      background: transparent; color: #f0f0f0;
      font-size: 15px; font-weight: 600;
      cursor: pointer;
      transition: background 0.12s, color 0.12s, transform 0.04s, border-color 0.12s;
    }
    #play:active { transform: scale(0.96); }
    #play.live   { background: #2ecc40; color: #000; border-color: #2ecc40; }
    #play.behind { background: #ff851b; color: #000; border-color: #ff851b; }
    #play.error  { background: #ff4136; color: #000; border-color: #ff4136; }
    .status {
      display: flex; align-items: center; gap: 8px;
      font-size: 13px; color: #999;
      font-variant-numeric: tabular-nums;
      flex: 1; min-width: 0;
    }
    .status .text {
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    }
    .dot {
      width: 8px; height: 8px; border-radius: 50%;
      background: #666; flex: 0 0 auto;
    }
    .dot.live   { background: #2ecc40; box-shadow: 0 0 6px rgba(46,204,64,0.7); }
    .dot.behind { background: #ff851b; }
    .dot.error  { background: #ff4136; }
    main {
      flex: 1; padding: 14px 16px 80px;
      overflow-y: auto;
    }
    .row {
      padding: 10px 0;
      border-bottom: 1px solid #1a1a1a;
      animation: fadein 0.18s ease-out;
    }
    .row:last-child { border-bottom: none; }
    .row .translation {
      font-size: 17px; line-height: 1.35;
      color: #f0f0f0;
      word-wrap: break-word;
    }
    .row .transcription {
      font-size: 12px; line-height: 1.35;
      color: #888;
      margin-top: 3px;
      word-wrap: break-word;
    }
    .row .meta {
      font-size: 10px;
      color: #555;
      margin-top: 4px;
      font-variant-numeric: tabular-nums;
    }
    @keyframes fadein {
      from { opacity: 0; transform: translateY(4px); }
      to   { opacity: 1; transform: translateY(0); }
    }
    .empty {
      text-align: center; color: #555;
      padding: 60px 16px;
      font-size: 14px;
    }
    audio { display: none; }
    </style>
    </head>
    <body>
    <header>
      <button id="play" type="button">Listen</button>
      <div class="status"><span id="dot" class="dot"></span><span id="text" class="text">Idle</span></div>
    </header>
    <main id="list"><div class="empty">Waiting for the first sentence…</div></main>
    <audio id="audio" preload="none"></audio>
    <script>
    (function () {
      const STREAM = '/live.wav';
      const EVENTS = '/events';
      const MAX_LATENCY = 3.0;   // seconds before we resync the audio
      const audio  = document.getElementById('audio');
      const btn    = document.getElementById('play');
      const dot    = document.getElementById('dot');
      const txt    = document.getElementById('text');
      const list   = document.getElementById('list');
      let mode = 'idle';   // idle | connecting | live | behind | error
      function setMode(m, label) {
        mode = m;
        btn.classList.remove('live','behind','error');
        dot.classList.remove('live','behind','error');
        if (m === 'live')        { btn.textContent = 'Live';     btn.classList.add('live');   dot.classList.add('live');   }
        else if (m === 'behind') { btn.textContent = 'Resync';   btn.classList.add('behind'); dot.classList.add('behind'); }
        else if (m === 'error')  { btn.textContent = 'Retry';    btn.classList.add('error');  dot.classList.add('error');  }
        else if (m === 'connecting') { btn.textContent = '…'; }
        else                     { btn.textContent = 'Listen'; }
        if (label) txt.textContent = label;
      }
      function start() {
        setMode('connecting', 'Connecting…');
        audio.src = STREAM + '?t=' + Date.now();
        audio.load();
        audio.play()
          .then(() => setMode('live', 'Streaming'))
          .catch(err => setMode('error', 'Tap to retry'));
      }
      function resync() {
        try { audio.pause(); } catch (e) {}
        audio.src = '';
        start();
      }
      btn.addEventListener('click', () => {
        if (mode === 'live')         { audio.pause(); setMode('idle', 'Paused'); }
        else if (mode === 'behind')  { resync(); }
        else                         { start(); }
      });
      // Drift watcher: when buffered.end runs ahead of currentTime, jump
      // forward; if even that doesn't catch up, hard-resync the stream.
      setInterval(() => {
        if (mode !== 'live') return;
        const b = audio.buffered;
        if (!b.length) return;
        const end = b.end(b.length - 1);
        const lag = end - audio.currentTime;
        if (lag > MAX_LATENCY) {
          try { audio.currentTime = end - 0.1; } catch (e) {}
          if (audio.buffered.length && audio.buffered.end(audio.buffered.length - 1) - audio.currentTime > MAX_LATENCY) {
            resync();
            return;
          }
        }
        txt.textContent = 'Streaming · ' + lag.toFixed(1) + 's';
      }, 500);
      audio.addEventListener('error',  () => { if (mode === 'live') setMode('error', 'Audio error'); });
      audio.addEventListener('ended',  () => { if (mode === 'live') { setMode('error', 'Disconnected'); setTimeout(resync, 600); } });
      audio.addEventListener('stalled',() => { if (mode === 'live') setMode('behind', 'Stalled'); });
      document.addEventListener('visibilitychange', () => {
        if (!document.hidden && mode === 'live') resync();
      });
      // Wake lock keeps the screen on while playing. Best-effort.
      let wake = null;
      audio.addEventListener('playing', async () => {
        if ('wakeLock' in navigator) {
          try { wake = await navigator.wakeLock.request('screen'); } catch (e) {}
        }
      });
      audio.addEventListener('pause',   () => { if (wake) { wake.release(); wake = null; } });
      // Transcript via SSE. EventSource handles reconnect automatically;
      // the server replays the session so far on each new connection,
      // so a brief drop won't lose context. Renders only finalized
      // sentences — no partials, no flicker.
      //
      // DOM cap: at most MAX_ROWS rows are kept attached. Long sessions
      // would otherwise grow unbounded — by hour 4 of a meeting that's
      // a few thousand nodes, which is where mobile Safari starts to
      // jank. Matches the server's replay cap so reconnect dedup still
      // works (every event in the replay was seen on the live channel).
      const MAX_ROWS = 200;
      const seen = new Set();
      function fmtTime(iso) {
        try { return new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }); }
        catch (e) { return ''; }
      }
      function trimRows(userIsNearBottom) {
        while (list.children.length > MAX_ROWS) {
          const oldest = list.firstElementChild;
          if (!oldest) break;
          const removedHeight = oldest.offsetHeight;
          if (oldest.dataset && oldest.dataset.key) {
            seen.delete(oldest.dataset.key);
          }
          list.removeChild(oldest);
          // If the user is reading history (scrolled up), keep their
          // viewport stable by shifting the scroll up by the height
          // of the row we just removed. If they're at the live edge
          // we let the bottom stay at the bottom.
          if (!userIsNearBottom) {
            window.scrollBy(0, -removedHeight);
          }
        }
      }
      function addRow(rec) {
        const key = (rec.start || '') + '|' + (rec.end || '') + '|' + (rec.transcription || '');
        if (seen.has(key)) return;
        seen.add(key);
        const empty = list.querySelector('.empty');
        if (empty) empty.remove();
        const row = document.createElement('div');
        row.className = 'row';
        row.dataset.key = key;
        const t = document.createElement('div');
        t.className = 'translation';
        t.textContent = rec.translation || rec.transcription || '';
        row.appendChild(t);
        if (rec.translation && rec.transcription && rec.translation !== rec.transcription) {
          const s = document.createElement('div');
          s.className = 'transcription';
          s.textContent = rec.transcription;
          row.appendChild(s);
        }
        const m = document.createElement('div');
        m.className = 'meta';
        m.textContent = fmtTime(rec.start) + ' · ' + (rec.source || '');
        row.appendChild(m);
        list.appendChild(row);
        const nearBottom = window.scrollY + window.innerHeight >= document.body.scrollHeight - 120;
        trimRows(nearBottom);
        if (nearBottom) window.scrollTo({ top: document.body.scrollHeight, behavior: 'smooth' });
      }
      function connectEvents() {
        const es = new EventSource(EVENTS);
        es.onmessage = (e) => {
          try { addRow(JSON.parse(e.data)); } catch (err) { /* ignore */ }
        };
        es.onerror = () => {
          // EventSource auto-retries; nothing to do.
        };
      }
      connectEvents();
    })();
    </script>
    </body>
    </html>
    """
}
