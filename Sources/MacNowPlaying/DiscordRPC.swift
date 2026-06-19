import Foundation

// IPC framing approach adapted from SwordRPC by Alejandro Alonso (MIT).

/// A dependency-free Discord Rich Presence client over Discord's local IPC.
///
/// Discord exposes a Unix domain socket at `$TMPDIR/discord-ipc-N` (N = 0..9) when
/// the desktop app is running. We speak its framed JSON protocol directly with raw
/// POSIX sockets — no OAuth, no client secret, no third-party socket library.
///
/// Frame format (one contiguous write each):
///   [UInt32 LE opcode][UInt32 LE length][UTF-8 JSON body]
/// Opcodes: 0 = HANDSHAKE, 1 = FRAME, 2 = CLOSE, 3 = PING, 4 = PONG.
///
/// All socket I/O runs on a private serial queue, so this type is safe to drive
/// from the main thread (PlayerModel) without blocking it. It degrades gracefully:
/// if Discord isn't running there's simply no socket to connect to and every call
/// is a quiet no-op until the next attempt.
final class DiscordRPC {
    /// The public "LocalMusic" Discord application ID. A client ID is NOT a secret
    /// (it's shipped in every Discord-integrated app and visible to anyone), so it's
    /// fine to hardcode. Whatever this application is *named* in Discord's Developer
    /// Portal is the text that renders after "Listening to" — here, "LocalMusic".
    private static let clientID = "834057528828100668"

    /// Activity type 2 = Listening, so the status reads "Listening to LocalMusic".
    /// (0 = Playing, 1 = Streaming, 2 = Listening, 3 = Watching.)
    private static let listeningType = 2

    private enum Opcode: UInt32 {
        case handshake = 0
        case frame = 1
        case close = 2
        case ping = 3
        case pong = 4
    }

    /// A presence snapshot. Timestamps are Unix epoch SECONDS (see encoding note in
    /// `setActivity`). Discord renders a live progress bar from start/end on its own,
    /// so we don't need per-second updates.
    struct Activity {
        var name: String      // shown after "Listening to" — we use "<title> - <artist>"
        var details: String   // first line — we use the track title
        var state: String     // second line — we use the artist
        var start: Date?
        var end: Date?
        // Large image. Discord's `large_image` can't take local artwork bytes — it
        // accepts an external https URL OR a pre-uploaded asset KEY. We pass either: a
        // resolved cover URL (iTunes/YouTube, see Artwork.swift), or — when no cover
        // resolved — the source's static asset key as a fallback. nil → no large image.
        var largeImage: String?
        var largeImageText: String?   // hover text — album (or title, or source label)
        // Small badge overlay (a per-source icon). Always an uploaded asset KEY
        // (`spotify`/`telegram`/`youtube-music`), never a URL. nil → no badge.
        var smallImage: String?
        var smallImageText: String?   // hover text — the source label
    }

    // All socket access is confined to this serial queue. fd is only touched here.
    private let queue = DispatchQueue(label: "DiscordRPC.ipc")
    private var fd: Int32 = -1
    private var isConnected = false

    // MARK: - Public API

    /// Discover the socket, connect, handshake and await READY. Idempotent and safe
    /// to call when Discord isn't running (it simply stays disconnected). Async work;
    /// the optional completion reports the outcome (used by the `--discord` probe).
    func connect(completion: ((_ socketFound: Bool, _ ready: Bool) -> Void)? = nil) {
        queue.async {
            if self.isConnected { completion?(true, true); return }
            let (found, ready) = self.connectLocked()
            completion?(found, ready)
        }
    }

    /// Send a SET_ACTIVITY frame, auto-connecting first if needed. A no-op (without
    /// error) when Discord isn't reachable.
    func setActivity(_ activity: Activity, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            if !self.isConnected { _ = self.connectLocked() }
            guard self.isConnected else { completion?(false); return }
            let ok = self.sendActivityLocked(activity)
            completion?(ok)
        }
    }

    /// Clear the presence (send `activity: null`). No-op when not connected.
    func clear() {
        queue.async {
            guard self.isConnected else { return }
            _ = self.sendActivityLocked(nil)
        }
    }

    /// Close the socket and mark disconnected.
    func disconnect() {
        queue.async { self.disconnectLocked() }
    }

    // MARK: - Codable activity model (snake_case wire keys)

    private struct ActivityPayload: Encodable {
        let type: Int
        let name: String
        let details: String
        let state: String
        let timestamps: Timestamps?
        // Built whenever ANY of the four asset fields is set (so a track with no cover
        // still ships its source badge); omitted entirely only when all are nil. Each
        // wire key is itself optional and drops out of the JSON when nil.
        let assets: Assets?

        struct Timestamps: Encodable {
            // Unix epoch SECONDS. Omitted keys (nil) drop out of the JSON.
            let start: Int?
            let end: Int?
        }

        struct Assets: Encodable {
            // `large_image` accepts an external https URL OR a pre-uploaded asset key;
            // `small_image` is always an asset key. The `*_text` fields are hover
            // labels. snake_case is the Discord wire format; nil keys drop out.
            let largeImage: String?
            let largeText: String?
            let smallImage: String?
            let smallText: String?
            enum CodingKeys: String, CodingKey {
                case largeImage = "large_image"
                case largeText = "large_text"
                case smallImage = "small_image"
                case smallText = "small_text"
            }
        }
    }

    private struct SetActivityArgs: Encodable {
        let pid: Int32
        // nil → encodes as `"activity": null`, which clears the presence.
        let activity: ActivityPayload?
    }

    private struct SetActivityCommand: Encodable {
        let cmd: String
        let args: SetActivityArgs
        let nonce: String

        enum CodingKeys: String, CodingKey {
            case cmd, args, nonce
        }
    }

    private struct Handshake: Encodable {
        let v: Int
        let clientID: String
        enum CodingKeys: String, CodingKey {
            case v
            case clientID = "client_id"
        }
    }

    // MARK: - Connection (all on `queue`)

    /// Returns (socketFound, ready). Leaves `isConnected`/`fd` set on success.
    private func connectLocked() -> (Bool, Bool) {
        guard let path = Self.socketPaths().first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return (false, false)   // Discord not running
        }

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return (true, false) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Copy the path into the fixed sun_path buffer. macOS sun_path is 104 bytes,
        // comfortably larger than "$TMPDIR/discord-ipc-9".
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(sock)
            return (true, false)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            // Capacity is pathBytes.count + 1 so the trailing NUL write at index
            // pathBytes.count stays within the rebound buffer (the guard above already
            // ensured count < sun_path size, so +1 still fits).
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                // Darwin.connect: our own connect() method shadows the global here.
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            close(sock)
            return (true, false)
        }

        fd = sock
        isConnected = true

        // Bound every blocking read with a receive timeout so a quiet-but-live socket
        // can never hang the serial queue forever. If Discord accepts a SET_ACTIVITY
        // but sends no reply, the post-send drain read would otherwise block the queue
        // indefinitely. On Darwin SO_RCVTIMEO takes a `timeval`; a timed-out read
        // returns -1 with errno EAGAIN/EWOULDBLOCK, which the read path treats as a
        // (healthy) timeout rather than EOF.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Handshake: opcode 0 with {"v":1,"client_id":...}. Discord answers with a
        // FRAME whose evt == "READY".
        guard let body = try? JSONEncoder().encode(Handshake(v: 1, clientID: Self.clientID)),
              writeFrame(.handshake, body) else {
            disconnectLocked()
            return (true, false)
        }

        // Await READY. A timeout or a closed/error socket here is a handshake failure
        // (we have nothing usable), so disconnect and report not-ready.
        guard case .frame(_, let replyBody) = readFrame() else {
            disconnectLocked()
            return (true, false)
        }
        let parsed = (try? JSONSerialization.jsonObject(with: replyBody)) as? [String: Any]
        let ready = (parsed?["evt"] as? String) == "READY"
        if !ready {
            disconnectLocked()
            return (true, false)
        }
        return (true, true)
    }

    private func disconnectLocked() {
        if fd >= 0 { close(fd) }
        fd = -1
        isConnected = false
    }

    /// Candidate socket paths discord-ipc-0 .. discord-ipc-9 in $TMPDIR (falling
    /// back to /tmp). First that exists/connects wins.
    private static func socketPaths() -> [String] {
        let base = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/"
        let dir = base.hasSuffix("/") ? base : base + "/"
        return (0...9).map { "\(dir)discord-ipc-\($0)" }
    }

    /// Discord measures its 2..128 activity-text limits in UTF-8 BYTES, not grapheme
    /// clusters, so we clamp by byte length. Truncate by dropping whole Characters from
    /// the end until the UTF-8 byte count is <= 128 (never split a character — that
    /// would emit invalid UTF-8). Then pad a too-short value (< 2 bytes) with a trailing
    /// space so it satisfies the 2-byte minimum.
    private static func clamp(_ s: String) -> String {
        var capped = s
        while capped.utf8.count > 128 {
            capped.removeLast()   // drop a whole Character, never a partial scalar
        }
        if capped.utf8.count < 2 { capped += " " }
        return capped
    }

    // MARK: - Activity send (on `queue`)

    /// Build + send a SET_ACTIVITY frame. Pass nil to clear. On any write/read error
    /// we mark disconnected so the next update retries the whole connection.
    private func sendActivityLocked(_ activity: Activity?) -> Bool {
        let payload: ActivityPayload?
        if let a = activity {
            // TIMESTAMP UNIT: Discord's LOCAL IPC SET_ACTIVITY takes Unix epoch
            // SECONDS (the Gateway/REST API uses milliseconds — different transport).
            // We ship seconds. If the progress bar ever renders wrong, multiply both
            // by 1000 here to switch to milliseconds.
            let start = a.start.map { Int($0.timeIntervalSince1970) }
            let end = a.end.map { Int($0.timeIntervalSince1970) }
            let timestamps = (start != nil || end != nil)
                ? ActivityPayload.Timestamps(start: start, end: end) : nil
            // Attach `assets` when ANY image/text field is set — so a no-cover track
            // still ships its source badge. Omit it entirely only when all are nil.
            let hasAnyAsset = a.largeImage != nil || a.largeImageText != nil
                || a.smallImage != nil || a.smallImageText != nil
            let assets = hasAnyAsset
                ? ActivityPayload.Assets(
                    largeImage: a.largeImage,
                    largeText: a.largeImageText.map(Self.clamp),
                    smallImage: a.smallImage,
                    smallText: a.smallImageText.map(Self.clamp))
                : nil
            payload = ActivityPayload(
                type: Self.listeningType,
                name: Self.clamp(a.name),
                details: Self.clamp(a.details),
                state: Self.clamp(a.state),
                timestamps: timestamps,
                assets: assets
            )
        } else {
            payload = nil
        }

        let command = SetActivityCommand(
            cmd: "SET_ACTIVITY",
            args: SetActivityArgs(pid: ProcessInfo.processInfo.processIdentifier, activity: payload),
            nonce: UUID().uuidString
        )
        guard let body = try? JSONEncoder().encode(command), writeFrame(.frame, body) else {
            disconnectLocked()
            return false
        }
        // Drain Discord's reply (a FRAME acknowledging the command, or a PING). We
        // service one frame so PINGs get a PONG; not strictly required per send, but
        // keeps the connection healthy on a quiet socket.
        servicePendingFrame()
        return true
    }

    /// Drain Discord's reply after a send and handle PING→PONG / CLOSE. A timeout here
    /// is normal — Discord often accepts a SET_ACTIVITY without replying — so a quiet
    /// but live socket must stay connected (just return). Only a real close/error
    /// disconnects; a real frame is handled.
    private func servicePendingFrame() {
        switch readFrame() {
        case .timedOut:
            return                  // quiet but healthy socket — leave it connected
        case .closed:
            disconnectLocked()
        case .frame(let op, let body):
            handle(op: op, body: body)
        }
    }

    private func handle(op: Opcode, body: Data) {
        switch op {
        case .ping:
            // Echo the same body back as a PONG to stay connected.
            _ = writeFrame(.pong, body)
        case .close:
            disconnectLocked()
        default:
            break   // FRAME ack / PONG — nothing to do.
        }
    }

    // MARK: - Framing (on `queue`)

    /// Write one frame: [opcode LE][length LE][body], contiguous. Endianness explicit.
    private func writeFrame(_ op: Opcode, _ body: Data) -> Bool {
        var packet = Data(capacity: 8 + body.count)
        var opLE = op.rawValue.littleEndian
        var lenLE = UInt32(body.count).littleEndian
        withUnsafeBytes(of: &opLE) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &lenLE) { packet.append(contentsOf: $0) }
        packet.append(body)
        return writeAll(packet)
    }

    /// Result of a single bounded read: a full payload, a (healthy) receive timeout on
    /// a quiet socket, or a closed/errored socket. Distinguishing timeout from EOF lets
    /// the post-send drain stay connected on a quiet socket while still tearing down a
    /// genuinely dead one.
    private enum ReadOutcome {
        case ok(Data)
        case timedOut
        case closed
    }

    /// A decoded frame, a timeout, or a closed/errored socket. Mirrors `ReadOutcome`
    /// but carries the decoded opcode + body on success.
    private enum FrameOutcome {
        case frame(Opcode, Data)
        case timedOut
        case closed
    }

    /// Read one frame, looping until the full 8-byte header then the full body are
    /// consumed (a stream socket can short-read). Propagates timeout vs. closed/error.
    private func readFrame() -> FrameOutcome {
        switch readExactly(8) {
        case .timedOut: return .timedOut
        case .closed: return .closed
        case .ok(let header):
            let opRaw = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) }
            let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
            guard let op = Opcode(rawValue: opRaw) else { return .closed }
            // Reject absurd frame lengths from an untrusted/desynced peer: Discord IPC
            // frames are tiny, so anything over 1 MB means we've lost framing. Treat as
            // a protocol error (caller disconnects) rather than allocating Int(length).
            guard length <= 1_000_000 else { return .closed }
            if length == 0 { return .frame(op, Data()) }
            switch readExactly(Int(length)) {
            case .timedOut: return .timedOut
            case .closed: return .closed
            case .ok(let body): return .frame(op, body)
            }
        }
    }

    /// Write every byte, looping over short writes. nil/error → false.
    private func writeAll(_ data: Data) -> Bool {
        guard fd >= 0 else { return false }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            let total = raw.count
            while offset < total {
                let n = write(fd, base + offset, total - offset)
                if n <= 0 { return false }   // error or closed
                offset += n
            }
            return true
        }
    }

    /// Read exactly `count` bytes, looping over short reads. Distinguishes a receive
    /// timeout (read() < 0 with errno EAGAIN/EWOULDBLOCK, from SO_RCVTIMEO) from EOF
    /// (read() == 0, peer closed) and other errors.
    private func readExactly(_ count: Int) -> ReadOutcome {
        guard fd >= 0 else { return .closed }
        guard count > 0 else { return .ok(Data()) }
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base + offset, count - offset)
            }
            if n > 0 {
                offset += n
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return .timedOut   // SO_RCVTIMEO fired — quiet socket, not dead
            }
            return .closed         // 0 = EOF (peer closed), <0 = error
        }
        return .ok(Data(buffer))
    }
}
