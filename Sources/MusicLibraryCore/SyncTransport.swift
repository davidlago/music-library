import CryptoKit
import Foundation
import Network
import Security

// MARK: Pairing

/// Keys for the sync connection. Pairing: the phone shows a short code, the Mac's user types it, and both derive
/// the same pre-shared key from it for the first connection, inside which the Mac hands the phone a random
/// 256-bit key that later sessions use. The code only protects that first exchange (it's short-lived and shown
/// only while pairing); the long-term key is what keeps later syncs private.
public enum SyncPairing {
    /// Crockford's base32 (no I, L, O or U), so a code read off the phone isn't mistyped as a lookalike.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let codeLength = 10
    static let pskIdentity = "musiclibrary-sync-v1"

    /// About 50 bits of randomness.
    public static func newCode() -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<codeLength).map { _ in alphabet.randomElement(using: &rng)! })
    }

    /// "ABCDE-FGHJK".
    public static func display(_ code: String) -> String {
        code.count == codeLength ? "\(code.prefix(5))-\(code.suffix(5))" : code
    }

    /// The code that was typed: case, spaces and dashes don't matter, and O, I and L are read as 0, 1 and 1.
    /// Nil when it isn't a whole code.
    public static func normalize(_ input: String) -> String? {
        var out = ""
        for ch in input.uppercased() where ch != " " && ch != "-" {
            let c: Character = ch == "O" ? "0" : (ch == "I" || ch == "L") ? "1" : ch
            guard alphabet.contains(c) else { return nil }
            out.append(c)
        }
        return out.count == codeLength ? out : nil
    }

    public static func pairingKey(code: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                                         salt: Data("MusicLibrary sync pairing".utf8), info: Data(pskIdentity.utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    public static func newKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// TCP + TLS with `key` as the pre-shared key, for both the phone's listener and the Mac's connection.
    public static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, psk as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

// MARK: Connection

/// A framed sync connection over `NWConnection`. One task reads at a time.
public actor SyncConnection {
    private var connection: NWConnection
    /// Makes a fresh connection to the same place, for another try (connections made here; nil for accepted ones).
    private let remake: (@Sendable () -> NWConnection)?
    private let queue = DispatchQueue(label: "MusicLibrary.sync.connection")
    private var decoder = SyncFrameDecoder()
    private var frames: [SyncFrame] = []

    /// How long each try to connect waits. Right after the Mac app starts, macOS can refuse its first local network
    /// connection ("Local network prohibited") and that connection never recovers, while a new one moments later
    /// goes through, so a connection made here is retried with a fresh one rather than waited on.
    public static let attemptTimeouts: [TimeInterval] = [6, 8, 10]
    /// The pause before each try after the first (a refused connection fails at once).
    static let retryPauses: [TimeInterval] = [1, 2]

    public init(_ connection: NWConnection) {
        self.connection = connection
        remake = nil
    }

    public init(endpoint: NWEndpoint, key: Data) {
        connection = NWConnection(to: endpoint, using: SyncPairing.parameters(key: key))
        remake = { NWConnection(to: endpoint, using: SyncPairing.parameters(key: key)) }
    }

    /// Starts the connection and waits until it's ready. One this side makes is tried again with a fresh connection
    /// when it can't be made (`attemptTimeouts`); a TLS handshake that fails because the keys differ throws at once.
    public func open(timeout: TimeInterval = 15) async throws {
        guard let remake else {
            try await Self.attempt(connection, queue: queue, timeout: timeout)
            return
        }
        var lastError: Error = SyncError.connection("timed out")
        let denied = Flag()
        for (index, wait) in Self.attemptTimeouts.enumerated() {
            if index > 0 {
                try await Task.sleep(for: .seconds(Self.retryPauses[min(index - 1, Self.retryPauses.count - 1)]))
                connection = remake()
            }
            do {
                try await Self.attempt(connection, queue: queue, timeout: wait, denied: denied)
                return
            } catch let error as AttemptError {
                if case .handshake(let message) = error { throw SyncError.connection(message) }
                lastError = error.syncError
            }
        }
        throw denied.value ? SyncError.localNetworkDenied : lastError
    }

    private enum AttemptError: Error {
        /// The TLS handshake failed: the keys differ, so trying again won't help.
        case handshake(String)
        case failed(String)

        var syncError: SyncError {
            switch self {
            case .handshake(let m), .failed(let m): SyncError.connection(m)
            }
        }
    }

    /// One try: waits for `connection` to be ready, `timeout` at most. `denied` is set when the system refuses local
    /// network access on the way.
    private static func attempt(_ connection: NWConnection, queue: DispatchQueue, timeout: TimeInterval,
                                denied: Flag = Flag()) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.pathUpdateHandler = { path in
                if path.unsatisfiedReason == .localNetworkDenied { denied.set() }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume() }
                case .failed(let error), .waiting(let error):
                    if once.claim() {
                        connection.cancel()
                        if case .tls = error {
                            cont.resume(throwing: AttemptError.handshake(error.localizedDescription))
                        } else {
                            cont.resume(throwing: AttemptError.failed(error.localizedDescription))
                        }
                    }
                case .cancelled:
                    if once.claim() { cont.resume(throwing: AttemptError.failed("cancelled")) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() {
                    connection.cancel()
                    cont.resume(throwing: AttemptError.failed("timed out"))
                }
            }
        }
    }

    public func send(_ message: SyncMessage) async throws {
        try await send(try SyncFrame.message(message))
    }

    public func sendChunk(_ data: Data) async throws {
        try await send(SyncFrame(kind: .chunk, payload: data))
    }

    private func send(_ frame: SyncFrame) async throws {
        let connection = connection
        let data = frame.encoded()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: SyncError.connection(error.localizedDescription)) } else { cont.resume() }
            })
        }
    }

    public func receive() async throws -> SyncFrame {
        while frames.isEmpty {
            frames += try decoder.append(try await receiveData())
        }
        return frames.removeFirst()
    }

    /// The next message; a `.failure` from the other side is thrown.
    public func receiveMessage() async throws -> SyncMessage {
        let message = try await receive().message()
        if case .failure(let text) = message { throw SyncError.remote(text) }
        return message
    }

    private func receiveData() async throws -> Data {
        let connection = connection
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: SyncError.connection(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(throwing: SyncError.connection("the other device closed the connection"))
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    public func close() {
        connection.cancel()
    }
}

/// A flag set from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return isSet }
    func set() { lock.lock(); isSet = true; lock.unlock() }
}

/// True the first time `claim()` is called.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

// MARK: Discovery

/// A device advertising sync on the local network: a phone (`SyncProtocol.serviceType`), or a Mac waiting for
/// one paired phone (`SyncProtocol.macServiceType`, with `phoneID` set).
public struct SyncPeer: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// The phone is showing a pairing code.
    public var isPairing: Bool
    public var endpoint: NWEndpoint
    /// The phone a Mac's service is for.
    public var phoneID: String?

    static let idKey = "id", pairingKey = "pair", phoneKey = "phone"
}

/// Listens for sync connections and advertises them: the phone's service (with its device ID and whether it's
/// pairing), or the Mac's for one paired phone. Hands each incoming connection to `onConnection`.
public final class SyncAdvertiser: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MusicLibrary.sync.listener")

    /// The phone. `port` is for tests (a fixed local port without Bonjour); the app lets the system pick one.
    public convenience init(deviceID: String, name: String, key: Data, pairing: Bool, advertise: Bool = true, port: NWEndpoint.Port = .any,
                            onState: @escaping @Sendable (NWListener.State) -> Void = { _ in },
                            onConnection: @escaping @Sendable (NWConnection) -> Void) throws {
        try self.init(type: SyncProtocol.serviceType, name: name, txt: [SyncPeer.idKey: deviceID, SyncPeer.pairingKey: pairing ? "1" : "0"],
                      key: key, advertise: advertise, port: port, onState: onState, onConnection: onConnection)
    }

    /// The Mac, for the paired phone `phoneID` (whose key it listens with).
    public convenience init(macID: String, phoneID: String, name: String, key: Data, advertise: Bool = true, port: NWEndpoint.Port = .any,
                            onState: @escaping @Sendable (NWListener.State) -> Void = { _ in },
                            onConnection: @escaping @Sendable (NWConnection) -> Void) throws {
        try self.init(type: SyncProtocol.macServiceType, name: name, txt: [SyncPeer.idKey: macID, SyncPeer.phoneKey: phoneID],
                      key: key, advertise: advertise, port: port, onState: onState, onConnection: onConnection)
    }

    private init(type: String, name: String, txt: [String: String], key: Data, advertise: Bool, port: NWEndpoint.Port,
                 onState: @escaping @Sendable (NWListener.State) -> Void, onConnection: @escaping @Sendable (NWConnection) -> Void) throws {
        listener = try NWListener(using: SyncPairing.parameters(key: key), on: port)
        if advertise {
            listener.service = NWListener.Service(name: name, type: type, txtRecord: NWTXTRecord(txt))
        }
        listener.stateUpdateHandler = onState
        listener.newConnectionHandler = onConnection
    }

    public var port: NWEndpoint.Port? { listener.port }

    public func start() { listener.start(queue: queue) }

    public func stop() { listener.cancel() }
}

/// Discovery: phones advertising sync nearby (the Mac), or Macs waiting for a phone (the phone, with
/// `type: SyncProtocol.macServiceType`).
public final class SyncBrowser: @unchecked Sendable {
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "MusicLibrary.sync.browser")

    public init(type: String = SyncProtocol.serviceType, onChange: @escaping @Sendable ([SyncPeer]) -> Void) {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { results, _ in
            onChange(results.compactMap(SyncBrowser.peer).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }

    static func peer(_ result: NWBrowser.Result) -> SyncPeer? {
        guard case .service(let name, _, _, _) = result.endpoint, case .bonjour(let txt) = result.metadata,
              let id = txt[SyncPeer.idKey], !id.isEmpty else { return nil }
        return SyncPeer(id: id, name: name, isPairing: txt[SyncPeer.pairingKey] == "1", endpoint: result.endpoint,
                        phoneID: txt[SyncPeer.phoneKey])
    }

    public func start() { browser.start(queue: queue) }

    public func stop() { browser.cancel() }
}
