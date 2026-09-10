# Tunnels M1+M2: Dialer Seam + Cloudflare Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SSH to hosts behind Cloudflare Tunnel from inside Sloop, via a new `Dialer` seam under `LibSSH2Transport` and a native Cloudflare Access client (WebSocket carrier + WKWebView browser SSO).

**Architecture:** A `Dialer` protocol in SloopKit produces the connected socket fd that libssh2 runs over; `TCPDialer` is the extracted status quo, `CloudflareAccessDialer` speaks the Access WebSocket carrier through a `SocketPairRelay` so libssh2 still sees a plain fd. Auth is a browser SSO sheet (WKWebView) that captures the `CF_Authorization` cookie into a Keychain-backed token store. Spec: `Docs/superpowers/specs/2026-08-12-tunnel-integrations-design.md`. Tailscale (M3) is a separate later plan.

**Tech Stack:** Swift 5.9, SloopKit (Foundation-only SPM target, XCTest via `swift test`), app layer via xcodegen variants (`project.ssh.yml` links the vendored libssh2 xcframework), URLSessionWebSocketTask, WKWebView, Security framework. Tests for the WebSocket dialer use Network.framework (test target only, macOS CI).

## Global Constraints

- SloopKit imports Foundation only (plus `FoundationNetworking` on Linux). WebKit/Security/Network go in the app layer or test target — never in `Sources/SloopKit`.
- Platforms: iOS 17, macOS 14 (Package.swift). tvOS is deferred; don't add tvOS conditionals.
- No fallbacks that mask errors. A tunnel that can't connect surfaces a specific `SSHError`; nothing silently retries over direct TCP. `MessageTransport`/`UnavailableCommandRunner`-style explanatory stand-ins are the codebase's established pattern for *unbuilt/unavailable* capability and are fine.
- Mosh is unavailable for tunneled hosts (UDP can't traverse Access). Enforced in `HostListModel.connect` and disabled in `HostEditView`.
- Existing saved hosts (JSON without `connectionMethod`) MUST keep decoding — default `.direct`.
- Every task ends with `swift test` green. Tasks touching `App/` also build the ssh variant: `xcodegen generate --spec project.ssh.yml && xcodebuild build -project Sloop.xcodeproj -scheme Sloop_macOS -sdk macosx CODE_SIGNING_ALLOWED=NO -quiet`.
- Commit after each task (message given per task). Never push.

**Deviations from spec (deliberate, small):**
- `Dialer.dial()` is synchronous `throws -> Int32`, not `async`: it's called from the transport's dedicated background thread (`LibSSH2Transport.run()`), which blocks on connect today. `CloudflareAccessDialer` bridges its async internals with a semaphore.
- The connection-method picker shows only Direct and Cloudflare Access; the Tailscale option arrives with M3 (an option that can't work yet would be worse than its absence).

---

### Task 1: `Dialer` protocol + `TCPDialer` (SloopKit)

**Files:**
- Create: `Sources/SloopKit/Net/Dialer.swift`
- Test: `Tests/SloopKitTests/DialerTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `public protocol Dialer: AnyObject { func dial() throws -> Int32 }` and `public final class TCPDialer: Dialer { public init(host: String, port: Int) }`. Later tasks (4, 7, 9) depend on these exact names.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SloopKitTests/DialerTests.swift
import XCTest
@testable import SloopKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class DialerTests: XCTestCase {

    /// Bind a TCP listener on 127.0.0.1 on an OS-assigned port.
    private func makeListener() -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        return (fd, Int(UInt16(bigEndian: out.sin_port)))
    }

    func testDialConnectsAndCarriesBytes() throws {
        let (listenFD, port) = makeListener()
        defer { close(listenFD) }

        // Echo one round on the accepted connection, then close it.
        let served = expectation(description: "served")
        Thread.detachNewThread {
            let conn = accept(listenFD, nil, nil)
            var buf = [UInt8](repeating: 0, count: 16)
            let n = read(conn, &buf, buf.count)
            _ = buf.withUnsafeBytes { write(conn, $0.baseAddress, n) }
            close(conn)
            served.fulfill()
        }

        let fd = try TCPDialer(host: "127.0.0.1", port: port).dial()
        defer { close(fd) }
        let hello: [UInt8] = [1, 2, 3, 4, 5]
        _ = hello.withUnsafeBytes { write(fd, $0.baseAddress, hello.count) }
        var back = [UInt8](repeating: 0, count: 16)
        let n = read(fd, &back, back.count)
        XCTAssertEqual(Array(back[0..<n]), hello)
        wait(for: [served], timeout: 5)
    }

    func testDialThrowsWhenNothingListens() {
        // Grab a port the OS just released so nothing is listening on it.
        let (fd, port) = makeListener()
        close(fd)
        XCTAssertThrowsError(try TCPDialer(host: "127.0.0.1", port: port).dial()) { error in
            guard case SSHError.connectionFailed = error else {
                return XCTFail("expected SSHError.connectionFailed, got \(error)")
            }
        }
    }

    func testDialThrowsOnUnresolvableHost() {
        XCTAssertThrowsError(
            try TCPDialer(host: "sloop-invalid.invalid", port: 22).dial())
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter DialerTests`
Expected: FAIL to compile — `cannot find 'TCPDialer' in scope`.

- [ ] **Step 3: Implement `Dialer.swift`**

The `TCPDialer` body is `LibSSH2Transport.openSocket` (`App/Sloop/SSH/LibSSH2Transport.swift:326-349`) moved verbatim, plus Linux conditionals so SloopKit keeps building anywhere:

```swift
// Sources/SloopKit/Net/Dialer.swift
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Produces the connected socket fd an SSH session runs over. This is the seam
/// tunnel integrations plug into: direct TCP today; Cloudflare Access and
/// Tailscale produce the same shape of fd by other means.
///
/// Contract: `dial()` is called at most once, on a background thread, and may
/// block. The returned fd is bidirectional and owned by the caller, who closes
/// it. The dialer instance must stay alive as long as the fd is in use (some
/// dialers pump the stream behind it).
public protocol Dialer: AnyObject {
    func dial() throws -> Int32
}

/// The status quo: resolve `host:port` and return a connected blocking TCP
/// socket.
public final class TCPDialer: Dialer {
    private let host: String
    private let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public func dial() throws -> Int32 {
        #if canImport(Glibc)
        let sockStream = Int32(SOCK_STREAM.rawValue)
        #else
        let sockStream = SOCK_STREAM
        #endif
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = sockStream
        hints.ai_protocol = Int32(IPPROTO_TCP)
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let addrs = result else {
            throw SSHError.connectionFailed("cannot resolve \(host)")
        }
        defer { freeaddrinfo(addrs) }

        var info: UnsafeMutablePointer<addrinfo>? = addrs
        while let candidate = info {
            let fd = socket(candidate.pointee.ai_family,
                            candidate.pointee.ai_socktype,
                            candidate.pointee.ai_protocol)
            if fd >= 0 {
                if connect(fd, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 {
                    return fd
                }
                close(fd)
            }
            info = candidate.pointee.ai_next
        }
        throw SSHError.connectionFailed("cannot connect to \(host):\(port)")
    }
}
```

Note the `addrinfo()` zero-init + field assignment (instead of the app file's positional initializer): Darwin and Glibc order `addrinfo` fields differently, and this form compiles on both.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter DialerTests`
Expected: 3 tests PASS.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SloopKit/Net/Dialer.swift Tests/SloopKitTests/DialerTests.swift
git commit -m "SloopKit: add Dialer seam + TCPDialer

The socket-producing step of an SSH connection becomes a protocol, so
tunnel integrations (Cloudflare Access, Tailscale) can plug in beneath
libssh2 without touching the transport."
```

---

### Task 2: `ConnectionMethod` on `SSHHost`

**Files:**
- Modify: `Sources/SloopKit/Model/SSHHost.swift`
- Test: `Tests/SloopKitTests/SSHHostCodableTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `public enum ConnectionMethod: String, Codable, Hashable, CaseIterable { case direct, cloudflareAccess, tailscale }`; `SSHHost.connectionMethod: ConnectionMethod` (init param defaulting to `.direct`). Tasks 9–10 depend on these exact names.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SloopKitTests/SSHHostCodableTests.swift
import XCTest
@testable import SloopKit

final class SSHHostCodableTests: XCTestCase {

    /// Hosts saved before connectionMethod existed must decode as .direct —
    /// a decode failure here would wipe the user's whole host list.
    func testLegacyJSONDecodesAsDirect() throws {
        let legacy = """
        {"id":"6F1E2D3C-0000-0000-0000-000000000001","alias":"box",
         "hostname":"box.example.com","port":22,"username":"matt",
         "auth":{"password":{}},"useMosh":false}
        """
        let host = try JSONDecoder().decode(SSHHost.self, from: Data(legacy.utf8))
        XCTAssertEqual(host.connectionMethod, .direct)
        XCTAssertEqual(host.alias, "box")
    }

    func testRoundTripsCloudflareAccess() throws {
        let host = SSHHost(alias: "tunnel", hostname: "ssh.example.com",
                           username: "matt", connectionMethod: .cloudflareAccess)
        let data = try JSONEncoder().encode(host)
        let back = try JSONDecoder().decode(SSHHost.self, from: data)
        XCTAssertEqual(back, host)
        XCTAssertEqual(back.connectionMethod, .cloudflareAccess)
    }

    /// A method this build doesn't know must FAIL to decode (Task 3 makes the
    /// store skip such hosts instead of silently connecting them directly).
    func testUnknownMethodThrows() {
        let future = """
        {"id":"6F1E2D3C-0000-0000-0000-000000000002","alias":"x",
         "hostname":"h","port":22,"username":"u","auth":{"password":{}},
         "useMosh":false,"connectionMethod":"wireguard"}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(SSHHost.self, from: Data(future.utf8)))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SSHHostCodableTests`
Expected: FAIL to compile — `extra argument 'connectionMethod' in call` / `has no member 'connectionMethod'`.

- [ ] **Step 3: Modify `SSHHost.swift`**

Add the enum above `SSHHost`, the property, the init parameter, and a custom `init(from:)` (encoding stays synthesized):

```swift
/// How the byte stream to the host is established. `.direct` is a plain TCP
/// connection; the others ride a tunnel via a matching `Dialer`.
public enum ConnectionMethod: String, Codable, Hashable, CaseIterable {
    case direct
    case cloudflareAccess
    case tailscale
}
```

In `SSHHost`, after `public var useMosh: Bool`:

```swift
    /// How to reach the host. Tunneled methods are SSH-only (no Mosh — UDP
    /// can't traverse them).
    public var connectionMethod: ConnectionMethod
```

Extend the memberwise init (new parameter after `useMosh`, keeping all existing defaults):

```swift
    public init(id: UUID = UUID(),
                alias: String,
                hostname: String,
                port: Int = 22,
                username: String,
                auth: AuthMethod = .password,
                useMosh: Bool = false,
                connectionMethod: ConnectionMethod = .direct) {
        self.id = id
        self.alias = alias
        self.hostname = hostname
        self.port = port
        self.username = username
        self.auth = auth
        self.useMosh = useMosh
        self.connectionMethod = connectionMethod
    }
```

Add below the init (decode-side only; a missing key means "written before this field existed", an unknown value still throws):

```swift
    private enum CodingKeys: String, CodingKey {
        case id, alias, hostname, port, username, auth, useMosh, connectionMethod
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        alias = try c.decode(String.self, forKey: .alias)
        hostname = try c.decode(String.self, forKey: .hostname)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        auth = try c.decode(AuthMethod.self, forKey: .auth)
        useMosh = try c.decode(Bool.self, forKey: .useMosh)
        connectionMethod = try c.decodeIfPresent(ConnectionMethod.self,
                                                 forKey: .connectionMethod) ?? .direct
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SSHHostCodableTests`
Expected: 3 tests PASS.

- [ ] **Step 5: Run the full suite** (SSH config parser and host store tests exercise `SSHHost` too)

Run: `swift test`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SloopKit/Model/SSHHost.swift Tests/SloopKitTests/SSHHostCodableTests.swift
git commit -m "SloopKit: SSHHost.connectionMethod (direct / cloudflareAccess / tailscale)

Missing key decodes as .direct so existing saved hosts keep loading;
an unknown value still throws rather than silently downgrading a
tunneled host to a direct connection."
```

---

### Task 3: `HostStore` lossy per-element decode

Today `HostStore.load()` does `(try? decode([SSHHost].self)) ?? []` — one undecodable host (e.g. saved by a newer build with a method this build doesn't know) silently wipes the entire list. Skip bad elements, keep the rest.

**Files:**
- Modify: `Sources/SloopKit/Model/HostStore.swift:24-27`
- Test: `Tests/SloopKitTests/HostStoreTests.swift` (create)

**Interfaces:**
- Consumes: `SSHHost` decode behavior from Task 2 (unknown `connectionMethod` throws).
- Produces: unchanged public API; `load()` becomes lossy per-element.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SloopKitTests/HostStoreTests.swift
import XCTest
@testable import SloopKit

final class HostStoreTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hoststore-\(UUID().uuidString).json")
    }

    func testSkipsUndecodableHostsInsteadOfWipingTheList() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        [
          {"id":"6F1E2D3C-0000-0000-0000-000000000001","alias":"good",
           "hostname":"a.example.com","port":22,"username":"matt",
           "auth":{"password":{}},"useMosh":false},
          {"this is": "not a host"},
          {"id":"6F1E2D3C-0000-0000-0000-000000000002","alias":"future",
           "hostname":"b.example.com","port":22,"username":"matt",
           "auth":{"password":{}},"useMosh":false,
           "connectionMethod":"wireguard"}
        ]
        """
        try Data(json.utf8).write(to: url)
        let store = HostStore(fileURL: url)
        XCTAssertEqual(store.hosts.map(\.alias), ["good"])
    }

    func testRoundTripSurvives() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HostStore(fileURL: url)
        store.upsert(SSHHost(alias: "t", hostname: "h", username: "u",
                             connectionMethod: .cloudflareAccess))
        let reloaded = HostStore(fileURL: url)
        XCTAssertEqual(reloaded.hosts.first?.connectionMethod, .cloudflareAccess)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter HostStoreTests`
Expected: `testSkipsUndecodableHostsInsteadOfWipingTheList` FAILS — decode of the whole array fails, list is `[]`, `["good"]` expected. (`testRoundTripSurvives` passes already.)

- [ ] **Step 3: Replace `load()`**

```swift
    public func load() {
        guard let data = try? Data(contentsOf: url) else { hosts = []; return }
        hosts = Self.decodeLossy(data)
    }

    /// Decode a host array, skipping elements that fail (e.g. written by a
    /// newer app with a connection method this build doesn't know) instead of
    /// wiping the whole list. Note the trade-off: the next `save()` persists
    /// only what decoded, dropping the skipped entries.
    static func decodeLossy(_ data: Data) -> [SSHHost] {
        struct Lossy: Decodable {
            let host: SSHHost?
            init(from decoder: Decoder) throws { host = try? SSHHost(from: decoder) }
        }
        let wrapped = (try? JSONDecoder().decode([Lossy].self, from: data)) ?? []
        return wrapped.compactMap(\.host)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter HostStoreTests`
Expected: 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SloopKit/Model/HostStore.swift Tests/SloopKitTests/HostStoreTests.swift
git commit -m "SloopKit: HostStore skips undecodable hosts instead of wiping the list"
```

---

### Task 4: Wire `Dialer` into the libssh2 transport + command runner (M1 complete)

Pure refactor: both `#if canImport(CSSH)` files stop opening their own sockets; the factories hand them a `TCPDialer`. No behavior change.

**Files:**
- Modify: `App/Sloop/SSH/LibSSH2Transport.swift` (init, `run()`, delete `openSocket` at lines 325-349)
- Modify: `App/Sloop/SSH/LibSSH2CommandRunner.swift` (init, `execute()`, delete its `openSocket` at lines 272 onward)
- Modify: `App/Sloop/SSH/TransportFactory.swift`
- Modify: `App/Sloop/SSH/CommandRunnerFactory.swift`

**Interfaces:**
- Consumes: `Dialer`, `TCPDialer` (Task 1).
- Produces: `LibSSH2Transport(host:credential:dialer:knownHosts:hostKeyVerifier:)` and `LibSSH2CommandRunner(host:credential:dialer:knownHosts:hostKeyVerifier:)`. Task 9 relies on the factories being the only construction sites.

- [ ] **Step 1: `LibSSH2Transport` — inject the dialer**

Add a stored property after `private let hostKeyVerifier: HostKeyVerifier`:

```swift
    private let dialer: Dialer
```

Change the init to (parameter added after `credential`):

```swift
    init(host: SSHHost,
         credential: Credential,
         dialer: Dialer,
         knownHosts: KnownHostsStore,
         hostKeyVerifier: HostKeyVerifier = AutoAcceptHostKeyVerifier()) {
        self.host = host
        self.credential = credential
        self.dialer = dialer
        self.knownHosts = knownHosts
        self.hostKeyVerifier = hostKeyVerifier
    }
```

In `run()`, replace `sock = try openSocket(host: host.hostname, port: host.port)` with:

```swift
            sock = try dialer.dial()
```

Delete the whole `openSocket(host:port:)` method (lines 325-349) — it now lives in `TCPDialer`.

- [ ] **Step 2: `LibSSH2CommandRunner` — same change**

Add `private let dialer: Dialer` after `private let hostKeyVerifier`, add `dialer: Dialer` to the init after `credential:` with `self.dialer = dialer`, replace `sock = try openSocket(host: host.hostname, port: host.port)` in `execute(_:)` with `sock = try dialer.dial()`, and delete its `openSocket` method. Also update the file's header comment: the connect path no longer contains socket code, so drop the sentence about the socket copy if present.

- [ ] **Step 3: Factories construct the `TCPDialer`**

In `TransportFactory.ssh`, the `#if canImport(CSSH)` branch becomes:

```swift
        return LibSSH2Transport(host: host, credential: credential,
                                dialer: TCPDialer(host: host.hostname, port: host.port),
                                knownHosts: knownHosts, hostKeyVerifier: hostKeyVerifier)
```

In `CommandRunnerFactory.ssh`, the `#if canImport(CSSH)` branch becomes:

```swift
        return LibSSH2CommandRunner(host: host, credential: credential,
                                    dialer: TCPDialer(host: host.hostname, port: host.port),
                                    knownHosts: knownHosts, hostKeyVerifier: hostKeyVerifier)
```

- [ ] **Step 4: Verify — SloopKit suite and the CSSH app build**

Run: `swift test`
Expected: all green.

Run: `xcodegen generate --spec project.ssh.yml && xcodebuild build -project Sloop.xcodeproj -scheme Sloop_macOS -sdk macosx CODE_SIGNING_ALLOWED=NO -quiet`
Expected: build succeeds (this compiles both CSSH files against the new inits).

- [ ] **Step 5: Commit**

```bash
git add App/Sloop/SSH/LibSSH2Transport.swift App/Sloop/SSH/LibSSH2CommandRunner.swift \
        App/Sloop/SSH/TransportFactory.swift App/Sloop/SSH/CommandRunnerFactory.swift
git commit -m "SSH: inject Dialer into libssh2 transport + command runner

Pure refactor completing the M1 seam: the duplicated openSocket copies
collapse into TCPDialer, and tunnel dialers can now slot in via the
factories."
```

---

### Task 5: `SocketPairRelay` (SloopKit)

Bridges a byte stream that only exists as callbacks (WebSocket frames) to a real fd for libssh2. One end is handed out (`localFD`); the relay pumps the other.

**Files:**
- Create: `Sources/SloopKit/Net/SocketPairRelay.swift`
- Test: `Tests/SloopKitTests/SocketPairRelayTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (Task 7 depends on these exact names):
  - `init() throws`, `var localFD: Int32`
  - `var onOutbound: ((Data) -> Void)?` — bytes the local side (libssh2) wrote
  - `var onLocalClosed: (() -> Void)?` — local side closed its fd
  - `func start()` — begin pumping (set callbacks first)
  - `func receive(_ data: Data)` — feed bytes from the remote toward the local side
  - `func finishInbound()` — remote EOF: local reader sees EOF
  - `func shutdown()` — tear down the relay's end

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SloopKitTests/SocketPairRelayTests.swift
import XCTest
@testable import SloopKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class SocketPairRelayTests: XCTestCase {

    func testOutboundBytesReachCallback() throws {
        let relay = try SocketPairRelay()
        var collected = Data()
        let got = expectation(description: "outbound")
        got.assertForOverFulfill = false
        relay.onOutbound = { data in
            collected.append(data)
            if collected.count >= 5 { got.fulfill() }
        }
        relay.start()
        let bytes: [UInt8] = [10, 20, 30, 40, 50]
        _ = bytes.withUnsafeBytes { write(relay.localFD, $0.baseAddress, bytes.count) }
        wait(for: [got], timeout: 5)
        XCTAssertEqual([UInt8](collected.prefix(5)), bytes)
        close(relay.localFD)
        relay.shutdown()
    }

    func testReceiveIsReadableOnLocalFD() throws {
        let relay = try SocketPairRelay()
        relay.start()
        relay.receive(Data([7, 8, 9]))
        var buf = [UInt8](repeating: 0, count: 8)
        let n = read(relay.localFD, &buf, buf.count)
        XCTAssertEqual(Array(buf[0..<n]), [7, 8, 9])
        close(relay.localFD)
        relay.shutdown()
    }

    func testFinishInboundGivesLocalReaderEOF() throws {
        let relay = try SocketPairRelay()
        relay.start()
        relay.receive(Data([1]))
        relay.finishInbound()
        var buf = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(read(relay.localFD, &buf, buf.count), 1)   // the byte
        XCTAssertEqual(read(relay.localFD, &buf, buf.count), 0)   // then EOF
        close(relay.localFD)
        relay.shutdown()
    }

    func testLocalCloseFiresCallbackAndLaterReceiveIsSafe() throws {
        let relay = try SocketPairRelay()
        let closed = expectation(description: "local closed")
        relay.onLocalClosed = { closed.fulfill() }
        relay.start()
        close(relay.localFD)
        wait(for: [closed], timeout: 5)
        relay.receive(Data([1, 2, 3]))   // must not crash (EPIPE, no SIGPIPE)
        relay.shutdown()
    }

    /// 1 MB through both directions exercises partial writes + backpressure
    /// (socketpair buffers are only a few KB).
    func testLargeTransfer() throws {
        let relay = try SocketPairRelay()
        let payload = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0) })
        var echoed = Data()
        let done = expectation(description: "echoed all")
        relay.onOutbound = { data in
            echoed.append(data)
            if echoed.count == payload.count { done.fulfill() }
        }
        relay.start()
        // Reader thread drains localFD so receive() can make progress, and
        // echoes everything back out through the fd.
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 32 * 1024)
            var received = 0
            while received < payload.count {
                let n = read(relay.localFD, &buf, buf.count)
                guard n > 0 else { return }
                received += n
                var off = 0
                while off < n {
                    let w = buf.withUnsafeBytes {
                        write(relay.localFD, $0.baseAddress!.advanced(by: off), n - off)
                    }
                    guard w > 0 else { return }
                    off += w
                }
            }
        }
        relay.receive(payload)
        wait(for: [done], timeout: 20)
        XCTAssertEqual(echoed, payload)
        close(relay.localFD)
        relay.shutdown()
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SocketPairRelayTests`
Expected: FAIL to compile — `cannot find 'SocketPairRelay' in scope`.

- [ ] **Step 3: Implement `SocketPairRelay.swift`**

```swift
// Sources/SloopKit/Net/SocketPairRelay.swift
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Bridges a byte stream that exists only as callbacks (e.g. WebSocket frames)
/// to a real socket fd, so libssh2 can treat a tunneled stream like a plain
/// TCP connection.
///
/// One end of a `socketpair` is handed out as `localFD` (give it to libssh2;
/// the caller closes it). The relay owns the other end: `receive(_:)` makes
/// remote bytes readable on `localFD`; bytes written to `localFD` surface via
/// `onOutbound`. Blocking writes against the pair's small kernel buffers give
/// natural backpressure in both directions.
public final class SocketPairRelay {
    public let localFD: Int32
    private let remoteFD: Int32
    private let lock = NSLock()
    private var remoteClosed = false

    /// Bytes the local side (libssh2) wrote, to be carried to the remote.
    public var onOutbound: ((Data) -> Void)?
    /// The local side closed its fd (or the pair broke); pumping has stopped.
    public var onLocalClosed: (() -> Void)?

    public init() throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, sockStreamType, 0, &fds) == 0 else {
            throw SSHError.connectionFailed("socketpair failed: errno \(errno)")
        }
        localFD = fds[0]
        remoteFD = fds[1]
        // A write after the peer closes must surface as EPIPE, not SIGPIPE.
        #if canImport(Darwin)
        for fd in fds {
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        #endif
    }

    /// Begin pumping. Set `onOutbound`/`onLocalClosed` before calling.
    public func start() {
        let thread = Thread { [weak self] in self?.pumpOutbound() }
        thread.name = "org.szatmary.sloop.relay"
        thread.start()
    }

    /// Feed bytes from the remote toward the local side. Blocks for
    /// backpressure; safe (a no-op) after the local side closed.
    public func receive(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = sendNoSignal(remoteFD, base.advanced(by: offset), raw.count - offset)
                if n <= 0 { return }   // EPIPE etc. — local side is gone
                offset += n
            }
        }
    }

    /// The remote sent EOF: after any buffered bytes, reads on `localFD`
    /// return 0 so libssh2 sees a normal connection close.
    public func finishInbound() {
        shutdown(remoteFD, Int32(SHUT_WR))
    }

    /// Tear down the relay's end. Call once the remote connection is finished.
    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard !remoteClosed else { return }
        remoteClosed = true
        close(remoteFD)
    }

    private func pumpOutbound() {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let n = read(remoteFD, &buffer, buffer.count)
            if n > 0 {
                onOutbound?(Data(buffer[0..<n]))
            } else if n == 0 || errno != EINTR {
                onLocalClosed?()
                return
            }
        }
    }

    private func sendNoSignal(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return write(fd, buf, count)          // SO_NOSIGPIPE is set
        #else
        return send(fd, buf, count, Int32(MSG_NOSIGNAL))
        #endif
    }
}

#if canImport(Glibc)
private let sockStreamType = Int32(SOCK_STREAM.rawValue)
#else
private let sockStreamType = SOCK_STREAM
#endif
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SocketPairRelayTests`
Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SloopKit/Net/SocketPairRelay.swift Tests/SloopKitTests/SocketPairRelayTests.swift
git commit -m "SloopKit: SocketPairRelay — callback byte streams as socket fds

The bridge that lets stream-shaped tunnels (Cloudflare's WebSocket
carrier) hand libssh2 a plain fd."
```

---

### Task 6: `AccessToken` + `AccessTokenStore` (SloopKit)

**Files:**
- Create: `Sources/SloopKit/Cloudflare/AccessToken.swift`
- Create: `Sources/SloopKit/Cloudflare/AccessTokenStore.swift`
- Test: `Tests/SloopKitTests/AccessTokenTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (Tasks 7–10 depend on these exact names):
  - `public struct AccessToken { public let raw: String; public let expiresAt: Date; public let audiences: [String]; public init?(raw: String); public var isExpired: Bool }`
  - `public protocol AccessTokenStore: AnyObject { func rawToken(for hostname: String) -> String?; func setRawToken(_ raw: String, for hostname: String) throws; func removeToken(for hostname: String) throws }`
  - extension method `validToken(for hostname: String) -> AccessToken?`
  - `public final class InMemoryAccessTokenStore: AccessTokenStore`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SloopKitTests/AccessTokenTests.swift
import XCTest
@testable import SloopKit

final class AccessTokenTests: XCTestCase {

    /// Build an unsigned JWT-shaped token with the given payload.
    private func jwt(_ payload: [String: Any]) -> String {
        func b64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(try! JSONSerialization.data(
            withJSONObject: ["alg": "RS256", "typ": "JWT"]))
        let body = b64url(try! JSONSerialization.data(withJSONObject: payload))
        return "\(header).\(body).fakesig"
    }

    func testParsesExpiryAndAudienceArray() throws {
        let exp = Date().addingTimeInterval(3600).timeIntervalSince1970
        let raw = jwt(["exp": exp, "aud": ["abc123", "def456"]])
        let token = try XCTUnwrap(AccessToken(raw: raw))
        XCTAssertEqual(token.expiresAt.timeIntervalSince1970, exp, accuracy: 1)
        XCTAssertEqual(token.audiences, ["abc123", "def456"])
        XCTAssertFalse(token.isExpired)
        XCTAssertEqual(token.raw, raw)
    }

    func testParsesSingleStringAudience() throws {
        let raw = jwt(["exp": Date().addingTimeInterval(600).timeIntervalSince1970,
                       "aud": "solo"])
        XCTAssertEqual(AccessToken(raw: raw)?.audiences, ["solo"])
    }

    func testPastExpiryIsExpired() throws {
        let raw = jwt(["exp": Date().addingTimeInterval(-60).timeIntervalSince1970])
        XCTAssertEqual(AccessToken(raw: raw)?.isExpired, true)
    }

    func testNearExpiryCountsAsExpired() throws {   // 60 s skew guard
        let raw = jwt(["exp": Date().addingTimeInterval(30).timeIntervalSince1970])
        XCTAssertEqual(AccessToken(raw: raw)?.isExpired, true)
    }

    func testGarbageIsNil() {
        XCTAssertNil(AccessToken(raw: "not-a-jwt"))
        XCTAssertNil(AccessToken(raw: "a.b"))
        XCTAssertNil(AccessToken(raw: "a.%%%%.c"))
        XCTAssertNil(AccessToken(raw: jwt(["aud": "x"])))   // no exp claim
    }

    func testStoreValidTokenFiltersExpiredAndGarbage() throws {
        let store = InMemoryAccessTokenStore()
        XCTAssertNil(store.validToken(for: "ssh.example.com"))

        try store.setRawToken(jwt(["exp": Date().addingTimeInterval(-60).timeIntervalSince1970]),
                              for: "ssh.example.com")
        XCTAssertNil(store.validToken(for: "ssh.example.com"))

        try store.setRawToken("garbage", for: "ssh.example.com")
        XCTAssertNil(store.validToken(for: "ssh.example.com"))

        let good = jwt(["exp": Date().addingTimeInterval(3600).timeIntervalSince1970])
        try store.setRawToken(good, for: "ssh.example.com")
        XCTAssertEqual(store.validToken(for: "ssh.example.com")?.raw, good)

        try store.removeToken(for: "ssh.example.com")
        XCTAssertNil(store.validToken(for: "ssh.example.com"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AccessTokenTests`
Expected: FAIL to compile — `cannot find 'AccessToken' in scope`.

- [ ] **Step 3: Implement `AccessToken.swift`**

```swift
// Sources/SloopKit/Cloudflare/AccessToken.swift
import Foundation

/// A Cloudflare Access application token (`CF_Authorization` JWT). The app is
/// the bearer, not the verifier, so only the payload's `exp`/`aud` claims are
/// parsed (no signature check) — enough to know when a fresh browser login is
/// needed before we bother dialing.
public struct AccessToken: Equatable {
    public let raw: String
    public let expiresAt: Date
    public let audiences: [String]

    /// Treat tokens expiring within this window as already expired, so a
    /// connection doesn't start on a token that dies mid-handshake.
    private static let expirySkew: TimeInterval = 60

    public init?(raw: String) {
        let segments = raw.split(separator: ".")
        guard segments.count == 3,
              let payloadData = Self.base64urlDecode(String(segments[1])),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData)
        else { return nil }
        self.raw = raw
        self.expiresAt = Date(timeIntervalSince1970: payload.exp)
        self.audiences = payload.aud?.values ?? []
    }

    public var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-Self.expirySkew)
    }

    private struct Payload: Decodable {
        let exp: Double
        let aud: Audience?
    }

    /// Access emits `aud` as an array; RFC 7519 also allows a bare string.
    private struct Audience: Decodable {
        let values: [String]
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let many = try? c.decode([String].self) {
                values = many
            } else {
                values = [try c.decode(String.self)]
            }
        }
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }
}
```

- [ ] **Step 4: Implement `AccessTokenStore.swift`**

```swift
// Sources/SloopKit/Cloudflare/AccessTokenStore.swift
import Foundation

/// Where Cloudflare Access tokens live, one per Access-protected hostname.
/// The app ships a Keychain-backed implementation; tests use
/// `InMemoryAccessTokenStore`. Kept as a protocol in SloopKit so the dial
/// plumbing can depend on it without pulling in the Security framework.
public protocol AccessTokenStore: AnyObject {
    func rawToken(for hostname: String) -> String?
    func setRawToken(_ raw: String, for hostname: String) throws
    func removeToken(for hostname: String) throws
}

public extension AccessTokenStore {
    /// The stored token, parsed, iff it exists and isn't (about to be)
    /// expired. `nil` always means "a browser login is needed".
    func validToken(for hostname: String) -> AccessToken? {
        guard let raw = rawToken(for: hostname),
              let token = AccessToken(raw: raw),
              !token.isExpired else { return nil }
        return token
    }
}

/// A non-persistent token store for tests and previews.
public final class InMemoryAccessTokenStore: AccessTokenStore {
    private var storage: [String: String] = [:]

    public init() {}

    public func rawToken(for hostname: String) -> String? { storage[hostname] }
    public func setRawToken(_ raw: String, for hostname: String) throws {
        storage[hostname] = raw
    }
    public func removeToken(for hostname: String) throws {
        storage[hostname] = nil
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter AccessTokenTests`
Expected: 7 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SloopKit/Cloudflare Tests/SloopKitTests/AccessTokenTests.swift
git commit -m "SloopKit: Cloudflare Access token model + store protocol

Client-side exp/aud parsing (bearer, not verifier) with a 60s skew
window, and the hostname-keyed store the Keychain implementation and
login flow plug into."
```

---

### Task 7: `CloudflareAccessDialer` + new `SSHError` cases

The native equivalent of `cloudflared access ssh`: a WebSocket to the Access-protected hostname with the JWT in the `cf-access-token` header; binary frames carry the raw SSH stream through a `SocketPairRelay`.

**Files:**
- Modify: `Sources/SloopKit/SSH/SSHError.swift`
- Create: `Sources/SloopKit/Cloudflare/CloudflareAccessDialer.swift`
- Test: `Tests/SloopKitTests/CloudflareAccessDialerTests.swift`

**Interfaces:**
- Consumes: `Dialer` (Task 1), `SocketPairRelay` (Task 5).
- Produces: `public final class CloudflareAccessDialer: NSObject, Dialer { public init(url: URL, hostname: String, token: String) }`; `SSHError.accessLoginRequired(host: String)` and `SSHError.accessDenied(host: String)`. Task 9 constructs the dialer; production uses `url = wss://<hostname>`, tests pass `ws://127.0.0.1:<port>`.

- [ ] **Step 0: Verify the carrier protocol against the cloudflared source** (the spec requires this before implementing)

Read `carrier/carrier.go` and `carrier/websocket.go` at
<https://github.com/cloudflare/cloudflared/tree/master/carrier> and confirm:
(a) the exact request header name that carries the Access JWT (this plan
assumes `cf-access-token`), and (b) that the WebSocket payload is the raw TCP
byte stream in binary frames with no extra framing. If either differs, adjust
the constants in this task's code and tests to match the source — the source
wins over this plan — and note the correction in the commit message.

- [ ] **Step 1: Add the error cases**

In `SSHError`, after `case channelFailure(String)`:

```swift
    /// The Cloudflare Access token for this host is missing, expired, or was
    /// rejected — a fresh browser login will fix it.
    case accessLoginRequired(host: String)
    /// Cloudflare Access authenticated the identity but the policy denied it.
    case accessDenied(host: String)
```

And in `errorDescription`:

```swift
        case .accessLoginRequired(let host):
            return "Cloudflare Access needs a browser login for \(host)"
        case .accessDenied(let host):
            return "Cloudflare Access denied this identity for \(host)"
```

- [ ] **Step 2: Write the failing tests**

Two servers: a real WebSocket echo (Network.framework's `NWProtocolWebSocket`) proves the data path, and a raw TCP server that reads the HTTP upgrade request proves the header is sent and maps deny/redirect responses to the right errors.

```swift
// Tests/SloopKitTests/CloudflareAccessDialerTests.swift
import XCTest
@testable import SloopKit
#if canImport(Network)
import Network

final class CloudflareAccessDialerTests: XCTestCase {

    // MARK: WebSocket echo server (data path)

    private final class WSEchoServer {
        let listener: NWListener
        private(set) var port: UInt16 = 0

        init() throws {
            let params = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            listener = try NWListener(using: params, on: .any)
        }

        func start() {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.newConnectionHandler = { conn in
                conn.start(queue: .global())
                self.echoLoop(conn)
            }
            listener.start(queue: .global())
            ready.wait()
            port = listener.port!.rawValue
        }

        private func echoLoop(_ conn: NWConnection) {
            conn.receiveMessage { data, context, _, error in
                guard let data, error == nil else { return }
                let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
                let ctx = NWConnection.ContentContext(identifier: "echo",
                                                      metadata: [meta])
                conn.send(content: data, contentContext: ctx,
                          completion: .contentProcessed { _ in })
                self.echoLoop(conn)
            }
        }
    }

    func testEchoesBytesThroughReturnedFD() throws {
        let server = try WSEchoServer()
        server.start()
        defer { server.listener.cancel() }

        let dialer = CloudflareAccessDialer(
            url: URL(string: "ws://127.0.0.1:\(server.port)")!,
            hostname: "ssh.example.com", token: "test-token")
        let fd = try dialer.dial()
        defer { close(fd) }

        let sent: [UInt8] = Array("SSH-2.0-Sloop\r\n".utf8)
        _ = sent.withUnsafeBytes { write(fd, $0.baseAddress, sent.count) }
        var buf = [UInt8](repeating: 0, count: 64)
        var got: [UInt8] = []
        while got.count < sent.count {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { break }
            got.append(contentsOf: buf[0..<n])
        }
        XCTAssertEqual(got, sent)
    }

    // MARK: Raw TCP server (header + error mapping)

    /// Accepts one TCP connection, captures what the client sent, replies with
    /// a canned HTTP response, closes.
    private final class CannedHTTPServer {
        let listener: NWListener
        private(set) var port: UInt16 = 0
        private(set) var request: String = ""
        private let response: String
        let sawRequest = XCTestExpectation(description: "request captured")

        init(response: String) throws {
            self.response = response
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start() {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.newConnectionHandler = { conn in
                conn.start(queue: .global())
                conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                    data, _, _, _ in
                    self.request = String(decoding: data ?? Data(), as: UTF8.self)
                    self.sawRequest.fulfill()
                    conn.send(content: Data(self.response.utf8),
                              completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                }
            }
            listener.start(queue: .global())
            ready.wait()
            port = listener.port!.rawValue
        }
    }

    func testSendsTokenHeaderAndMapsForbiddenToAccessDenied() throws {
        let server = try CannedHTTPServer(
            response: "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
        server.start()
        defer { server.listener.cancel() }

        let dialer = CloudflareAccessDialer(
            url: URL(string: "ws://127.0.0.1:\(server.port)")!,
            hostname: "ssh.example.com", token: "sekrit-token")
        XCTAssertThrowsError(try dialer.dial()) { error in
            guard case SSHError.accessDenied(let host) = error else {
                return XCTFail("expected accessDenied, got \(error)")
            }
            XCTAssertEqual(host, "ssh.example.com")
        }
        wait(for: [server.sawRequest], timeout: 5)
        XCTAssertTrue(server.request.lowercased().contains("cf-access-token: sekrit-token"),
                      "upgrade request must carry the token header; got:\n\(server.request)")
    }

    func testMapsRedirectToAccessLoginRequired() throws {
        let server = try CannedHTTPServer(
            response: "HTTP/1.1 302 Found\r\nLocation: https://login.example\r\nContent-Length: 0\r\n\r\n")
        server.start()
        defer { server.listener.cancel() }

        let dialer = CloudflareAccessDialer(
            url: URL(string: "ws://127.0.0.1:\(server.port)")!,
            hostname: "ssh.example.com", token: "stale")
        XCTAssertThrowsError(try dialer.dial()) { error in
            guard case SSHError.accessLoginRequired = error else {
                return XCTFail("expected accessLoginRequired, got \(error)")
            }
        }
    }
}
#endif
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter CloudflareAccessDialerTests`
Expected: FAIL to compile — `cannot find 'CloudflareAccessDialer' in scope`.

- [ ] **Step 4: Implement `CloudflareAccessDialer.swift`**

```swift
// Sources/SloopKit/Cloudflare/CloudflareAccessDialer.swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Dials an SSH host behind Cloudflare Tunnel the way `cloudflared access ssh`
/// does: a WebSocket to the Access-protected hostname, authenticated by the
/// Access JWT in the `cf-access-token` header, with binary frames carrying the
/// raw SSH byte stream. A `SocketPairRelay` turns that into the fd libssh2
/// expects.
///
/// Single-use, like every `Dialer`. The instance must outlive the returned fd
/// — it owns the WebSocket task and the relay pumping it.
public final class CloudflareAccessDialer: NSObject, Dialer {
    private let url: URL
    private let hostname: String
    private let token: String
    private let openTimeout: TimeInterval

    private var relay: SocketPairRelay?
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let opened = DispatchSemaphore(value: 0)
    private var openError: Error?

    /// - Parameters:
    ///   - url: `wss://<hostname>` in production; tests inject `ws://127.0.0.1:…`.
    ///   - hostname: the Access app hostname, used in error messages.
    ///   - token: the raw Access JWT to present.
    public init(url: URL, hostname: String, token: String,
                openTimeout: TimeInterval = 20) {
        self.url = url
        self.hostname = hostname
        self.token = token
        self.openTimeout = openTimeout
    }

    public func dial() throws -> Int32 {
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "cf-access-token")

        let session = URLSession(configuration: .ephemeral,
                                 delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()

        guard opened.wait(timeout: .now() + openTimeout) == .success else {
            tearDown()
            throw SSHError.connectionFailed("timed out connecting to \(hostname)")
        }
        if let error = openError {
            defer { tearDown() }
            throw mapOpenFailure(error)
        }

        let relay = try SocketPairRelay()
        self.relay = relay
        relay.onOutbound = { [weak task] data in
            task?.send(.data(data)) { _ in }   // send failures surface via receive
        }
        relay.onLocalClosed = { [weak self] in self?.tearDown() }
        relay.start()
        receiveLoop(task, relay)
        return relay.localFD
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, _ relay: SocketPairRelay) {
        task.receive { [weak self] result in
            switch result {
            case .success(.data(let data)):
                relay.receive(data)
                self?.receiveLoop(task, relay)
            case .success(.string(let text)):
                relay.receive(Data(text.utf8))
                self?.receiveLoop(task, relay)
            case .success:
                self?.receiveLoop(task, relay)
            case .failure:
                relay.finishInbound()   // remote closed; libssh2 sees EOF
            }
        }
    }

    /// Read the HTTP status behind a failed upgrade and name the real problem.
    private func mapOpenFailure(_ error: Error) -> Error {
        guard let http = task?.response as? HTTPURLResponse else {
            return SSHError.connectionFailed(
                "\(hostname): \(error.localizedDescription)")
        }
        switch http.statusCode {
        case 300...399, 401:                       // Access bounce to the IdP
            return SSHError.accessLoginRequired(host: hostname)
        case 403:
            return SSHError.accessDenied(host: hostname)
        default:
            return SSHError.connectionFailed(
                "\(hostname): HTTP \(http.statusCode) during WebSocket upgrade")
        }
    }

    private func tearDown() {
        task?.cancel(with: .normalClosure, reason: nil)
        session?.finishTasksAndInvalidate()
        relay?.shutdown()
    }
}

extension CloudflareAccessDialer: URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        opened.signal()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        if let error {
            openError = error
            opened.signal()   // no-op if already open; then receive() reports it
        }
    }

    /// Don't follow the Access 302 to the IdP — surface it so the app can run
    /// the browser login instead.
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter CloudflareAccessDialerTests`
Expected: 3 tests PASS. If `testEchoesBytesThroughReturnedFD` is flaky on `receiveMessage` fragmentation, accumulate until the byte count matches (the client side already loops on `read`).

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add Sources/SloopKit/SSH/SSHError.swift Sources/SloopKit/Cloudflare/CloudflareAccessDialer.swift \
        Tests/SloopKitTests/CloudflareAccessDialerTests.swift
git commit -m "SloopKit: CloudflareAccessDialer — native 'cloudflared access ssh'

WebSocket carrier with the Access JWT in cf-access-token, redirects
surfaced as accessLoginRequired and 403 as accessDenied instead of
being followed, stream bridged to an fd via SocketPairRelay."
```

---

### Task 8: `KeychainAccessTokenStore` (app layer)

**Files:**
- Create: `App/Sloop/Cloudflare/KeychainAccessTokenStore.swift`

**Interfaces:**
- Consumes: `AccessTokenStore` (Task 6).
- Produces: `final class KeychainAccessTokenStore: AccessTokenStore` with `init(service: String = "org.szatmary.sloop.access-tokens")`. Task 9 constructs it.

- [ ] **Step 1: Implement, mirroring `KeychainCredentialStore` exactly** (same file layout, same error helper; account = hostname, value = UTF-8 token)

```swift
// App/Sloop/Cloudflare/KeychainAccessTokenStore.swift
import Foundation
import SloopKit
#if canImport(Security)
import Security

/// Keychain-backed `AccessTokenStore`. One generic-password item per
/// Access-protected hostname, holding the raw `CF_Authorization` JWT.
///
/// Tokens never touch `HostStore`'s plain-JSON file — only the keychain.
final class KeychainAccessTokenStore: AccessTokenStore {
    private let service: String

    init(service: String = "org.szatmary.sloop.access-tokens") {
        self.service = service
    }

    func rawToken(for hostname: String) -> String? {
        var query = baseQuery(for: hostname)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setRawToken(_ raw: String, for hostname: String) throws {
        let data = Data(raw.utf8)
        let query = baseQuery(for: hostname)

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes: [String: Any] = [kSecValueData as String: data]
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard update == errSecSuccess else { throw keychainError(update) }
        } else {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let add = SecItemAdd(insert as CFDictionary, nil)
            guard add == errSecSuccess else { throw keychainError(add) }
        }
    }

    func removeToken(for hostname: String) throws {
        let status = SecItemDelete(baseQuery(for: hostname) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func baseQuery(for hostname: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostname,
        ]
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "keychain error \(status)"])
    }
}
#endif
```

- [ ] **Step 2: Verify it builds** (Keychain isn't reachable from `swift test`; the protocol's logic is covered by `InMemoryAccessTokenStore` tests in Task 6)

Run: `xcodegen generate --spec project.ssh.yml && xcodebuild build -project Sloop.xcodeproj -scheme Sloop_macOS -sdk macosx CODE_SIGNING_ALLOWED=NO -quiet`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add App/Sloop/Cloudflare/KeychainAccessTokenStore.swift
git commit -m "App: Keychain-backed AccessTokenStore, one item per Access hostname"
```

---

### Task 9: Wire Cloudflare into `TransportFactory` + `HostListModel`

**Files:**
- Modify: `App/Sloop/SSH/TransportFactory.swift`
- Modify: `App/Sloop/Views/HostListModel.swift`

**Interfaces:**
- Consumes: `ConnectionMethod` (Task 2), `CloudflareAccessDialer`/`SSHError` cases (Task 7), `AccessTokenStore`/`validToken` (Task 6), `KeychainAccessTokenStore` (Task 8).
- Produces (Task 10 depends on these):
  - `TransportFactory.ssh(host:credential:knownHosts:hostKeyVerifier:accessTokens:)` — new final parameter `accessTokens: AccessTokenStore`
  - `HostListModel.needsAccessLogin(_ host: SSHHost) -> Bool`
  - `HostListModel.storeAccessToken(_ raw: String, for host: SSHHost) throws`

- [ ] **Step 1: Rewrite `TransportFactory`**

```swift
import Foundation
import SloopKit

/// Chooses a concrete `Transport` for a host. When the libssh2 xcframework is
/// linked (`CSSH` importable) it builds a real SSH connection over a `Dialer`
/// matching the host's connection method; otherwise it returns a
/// `MessageTransport` explaining what's missing, so the app stays usable
/// during the libssh2 bring-up.
enum TransportFactory {
    static func ssh(host: SSHHost,
                    credential: Credential,
                    knownHosts: KnownHostsStore,
                    hostKeyVerifier: HostKeyVerifier,
                    accessTokens: AccessTokenStore) -> Transport {
        #if canImport(CSSH)
        guard let dialer = dialer(for: host, accessTokens: accessTokens) else {
            return unavailable(for: host)
        }
        return LibSSH2Transport(host: host, credential: credential,
                                dialer: dialer,
                                knownHosts: knownHosts, hostKeyVerifier: hostKeyVerifier)
        #else
        return MessageTransport(message:
            "SSH isn't built into this app yet.\r\n" +
            "Add Vendor/libssh2.xcframework and rebuild — see Docs/SSH.md.\r\n\r\n" +
            "The Local terminal on the home screen works now.\r\n")
        #endif
    }

    #if canImport(CSSH)
    /// The dialer for the host's connection method, or nil when the method
    /// can't produce one right now (no Access token, unbuilt integration).
    private static func dialer(for host: SSHHost,
                               accessTokens: AccessTokenStore) -> Dialer? {
        switch host.connectionMethod {
        case .direct:
            return TCPDialer(host: host.hostname, port: host.port)
        case .cloudflareAccess:
            guard let url = URL(string: "wss://\(host.hostname)"),
                  let token = accessTokens.validToken(for: host.hostname) else {
                return nil
            }
            return CloudflareAccessDialer(url: url, hostname: host.hostname,
                                          token: token.raw)
        case .tailscale:
            return nil
        }
    }

    /// Why `dialer(for:)` returned nil, as terminal text. The host list's
    /// pre-connect gate normally prevents the Access case from being seen.
    private static func unavailable(for host: SSHHost) -> Transport {
        switch host.connectionMethod {
        case .cloudflareAccess:
            return MessageTransport(message:
                "Cloudflare Access needs a browser login for \(host.hostname).\r\n" +
                "Go back to the host list and reconnect to sign in.\r\n")
        case .tailscale:
            return MessageTransport(message:
                "Tailscale support isn't built into this app yet — see Docs/ROADMAP.md.\r\n")
        case .direct:
            return MessageTransport(message:
                "Unable to connect to \(host.hostname).\r\n")
        }
    }
    #endif
}
```

- [ ] **Step 2: Update `HostListModel`**

Add a stored property after `private let credentials: CredentialStore`:

```swift
    private let accessTokens: AccessTokenStore
```

In `init()`, inside the existing `#if canImport(Security)` block add `accessTokens = KeychainAccessTokenStore()`, and in the `#else` branch add `accessTokens = InMemoryAccessTokenStore()`.

Add after `delete(_:)`:

```swift
    /// True when connecting to this host must be preceded by a Cloudflare
    /// Access browser login (no stored token, or it expired).
    func needsAccessLogin(_ host: SSHHost) -> Bool {
        host.connectionMethod == .cloudflareAccess
            && accessTokens.validToken(for: host.hostname) == nil
    }

    /// Persist a freshly captured Access token for the host's hostname.
    func storeAccessToken(_ raw: String, for host: SSHHost) throws {
        try accessTokens.setRawToken(raw, for: host.hostname)
    }
```

In `connect(_:)`, capture the store next to `knownHosts` and pass it through, and gate Mosh on the connection method. The full updated body:

```swift
    func connect(_ host: SSHHost) -> TerminalSession {
        let credential = credentials.credential(for: host.id) ?? Credential()
        let knownHosts = self.knownHosts
        let accessTokens = self.accessTokens

        // Resolves the Access token at call time, so a reconnect after a fresh
        // login picks up the new token.
        let makeSSH: () -> Transport = {
            TransportFactory.ssh(host: host,
                                 credential: credential,
                                 knownHosts: knownHosts,
                                 hostKeyVerifier: HostKeyPrompter.shared,
                                 accessTokens: accessTokens)
        }

        return TerminalSession(title: host.alias) {
            // Mosh needs UDP, which no tunnel method carries — tunneled hosts
            // are SSH-only regardless of the saved toggle.
            guard host.useMosh, host.connectionMethod == .direct else { return makeSSH() }
            // The real Mosh UDP/SSP transport is only built into the Mosh variant
            // (project.mosh.yml, which defines SLOOP_MOSH); elsewhere
            // `makeMoshTransport` stays nil and the composite transport falls back
            // to SSH after probing.
            var makeMosh: ((MoshBootstrap) -> Transport)? = nil
            #if SLOOP_MOSH
            makeMosh = { bootstrap in
                MoshTransport(host: host.hostname, bootstrap: bootstrap)
            }
            #endif
            return MoshOrSSHTransport(
                useMosh: true,
                makeCommandRunner: {
                    CommandRunnerFactory.ssh(host: host,
                                             credential: credential,
                                             knownHosts: knownHosts,
                                             hostKeyVerifier: HostKeyPrompter.shared)
                },
                makeSSHTransport: makeSSH,
                makeMoshTransport: makeMosh)
        }
    }
```

- [ ] **Step 3: Verify — build both variants and run the suite**

Run: `swift test`
Expected: all green.

Run: `xcodegen generate --spec project.ssh.yml && xcodebuild build -project Sloop.xcodeproj -scheme Sloop_macOS -sdk macosx CODE_SIGNING_ALLOWED=NO -quiet`
Expected: build succeeds.

Run: `xcodegen generate && xcodebuild build -project Sloop.xcodeproj -scheme Sloop_macOS -sdk macosx CODE_SIGNING_ALLOWED=NO -quiet`
Expected: base (no-CSSH) variant also builds — the factory's `#else` branch must compile with the new parameter.

- [ ] **Step 4: Commit**

```bash
git add App/Sloop/SSH/TransportFactory.swift App/Sloop/Views/HostListModel.swift
git commit -m "App: route cloudflareAccess hosts through CloudflareAccessDialer

TransportFactory picks the dialer from the host's connection method;
HostListModel gates connect on a valid Access token and keeps tunneled
hosts SSH-only (Mosh needs UDP)."
```

---

### Task 10: Browser SSO sheet + host UI

**Files:**
- Create: `App/Sloop/Cloudflare/AccessLoginView.swift`
- Modify: `App/Sloop/Views/HostListView.swift`
- Modify: `App/Sloop/Views/HostEditView.swift`

**Interfaces:**
- Consumes: `HostListModel.needsAccessLogin` / `storeAccessToken` (Task 9), `ConnectionMethod` (Task 2).
- Produces: `AccessLoginView(hostname: String, onToken: @escaping (String) -> Void)` — a sheet; calls `onToken` once with the raw JWT when the `CF_Authorization` cookie for the hostname appears.

- [ ] **Step 1: Implement `AccessLoginView.swift`**

```swift
// App/Sloop/Cloudflare/AccessLoginView.swift
import SwiftUI
import WebKit

/// Browser SSO for a Cloudflare Access-protected hostname. Loads
/// `https://<hostname>`, lets Access bounce through the IdP, and captures the
/// resulting `CF_Authorization` cookie — which IS the Access JWT — from the
/// web view's cookie store. The default (persistent) store is used on purpose:
/// the IdP session survives, so token renewals need no password re-entry.
struct AccessLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let hostname: String
    let onToken: (String) -> Void

    var body: some View {
        NavigationStack {
            AccessWebView(hostname: hostname) { token in
                onToken(token)
                dismiss()
            }
            .navigationTitle(hostname)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }
}

/// The platform-wrapped WKWebView doing the actual work.
private struct AccessWebView {
    let hostname: String
    let onToken: (String) -> Void

    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = coordinator
        if let url = URL(string: "https://\(hostname)") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(hostname: hostname, onToken: onToken)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let hostname: String
        private let onToken: (String) -> Void
        private var delivered = false

        init(hostname: String, onToken: @escaping (String) -> Void) {
            self.hostname = hostname
            self.onToken = onToken
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // After every completed navigation (IdP redirects included), look
            // for the Access cookie scoped to our hostname.
            webView.configuration.websiteDataStore.httpCookieStore
                .getAllCookies { [weak self] cookies in
                    guard let self, !self.delivered else { return }
                    let match = cookies.first { cookie in
                        cookie.name == "CF_Authorization" && self.domainMatches(cookie.domain)
                    }
                    if let match {
                        self.delivered = true
                        self.onToken(match.value)
                    }
                }
        }

        /// Cookie domains may be exact ("ssh.example.com") or parent-scoped
        /// (".example.com").
        private func domainMatches(_ cookieDomain: String) -> Bool {
            let domain = cookieDomain.hasPrefix(".")
                ? String(cookieDomain.dropFirst()) : cookieDomain
            return hostname == domain || hostname.hasSuffix("." + domain)
        }
    }
}

#if os(iOS)
extension AccessWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
extension AccessWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
```

- [ ] **Step 2: Present the sheet from `HostListView`**

Add state after `@State private var editing: SSHHost?`:

```swift
    @State private var accessLogin: SSHHost?
```

Change the host row's connect action (currently `Button { open(model.connect(host)) }`) to:

```swift
                            Button { connect(host) } label: {
```

Add next to the private `open(_:)` helper:

```swift
    /// Connect, first running the Cloudflare Access browser login when the
    /// host needs a (fresh) token.
    private func connect(_ host: SSHHost) {
        if model.needsAccessLogin(host) {
            accessLogin = host
        } else {
            open(model.connect(host))
        }
    }
```

Add a sheet after the existing `.sheet(item: $editing)`:

```swift
            .sheet(item: $accessLogin) { host in
                AccessLoginView(hostname: host.hostname) { token in
                    do {
                        try model.storeAccessToken(token, for: host)
                        open(model.connect(host))
                    } catch {
                        importResult = "Couldn't store the Access token: \(error.localizedDescription)"
                    }
                }
            }
```

(`importResult` drives the existing alert; the alert title "Import SSH Config" no longer fits every message — change the alert title string to `"Sloop"` in the same edit.)

In `HostRow`, after the existing `if host.useMosh` capsule, add a tunnel badge:

```swift
                if host.connectionMethod == .cloudflareAccess {
                    Text("cloudflare")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.orange.opacity(0.2), in: Capsule())
                }
```

- [ ] **Step 3: Connection-method picker in `HostEditView`**

In the `Section("Connection")`, replace the `Stepper("Port: …")` line with:

```swift
                    Picker("Connect via", selection: $host.connectionMethod) {
                        Text("Direct").tag(ConnectionMethod.direct)
                        Text("Cloudflare Access").tag(ConnectionMethod.cloudflareAccess)
                    }

                    if host.connectionMethod == .cloudflareAccess {
                        Text("The hostname above is the Access application's public hostname. A browser sign-in runs on first connect.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Stepper("Port: \(host.port)", value: $host.port, in: 1...65535)
                    }
```

Replace the `Section("Options")` body with:

```swift
                Section("Options") {
                    Toggle("Use Mosh", isOn: $host.useMosh)
                        .disabled(host.connectionMethod != .direct)
                    if host.connectionMethod != .direct {
                        Text("Mosh needs UDP, which can't pass through this tunnel — SSH is used instead.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
```

And keep the model consistent when the method changes — add to the `Form` (after the closing brace of the last `Section`):

```swift
            .onChange(of: host.connectionMethod) { _, method in
                if method != .direct { host.useMosh = false }
            }
```

- [ ] **Step 4: Verify — build iOS + macOS**

Run: `xcodegen generate --spec project.ssh.yml && xcodebuild build -project Sloop.xcodeproj -scheme Sloop_macOS -sdk macosx CODE_SIGNING_ALLOWED=NO -quiet && xcodebuild build -project Sloop.xcodeproj -scheme Sloop_iOS -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO -quiet`
Expected: both builds succeed.

Run: `swift test`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add App/Sloop/Cloudflare/AccessLoginView.swift App/Sloop/Views/HostListView.swift App/Sloop/Views/HostEditView.swift
git commit -m "App: Cloudflare Access browser login + connection-method UI

WKWebView SSO sheet captures the CF_Authorization cookie into the
keychain store; host editor grows a Direct/Cloudflare picker, hides
the port for Access hosts, and pins tunneled hosts to SSH-only."
```

---

### Task 11: Docs + real-tunnel verification gate

**Files:**
- Modify: `Docs/ARCHITECTURE.md` (add the Dialer seam + Cloudflare section where transports are described)
- Modify: `Docs/ROADMAP.md` (record M1+M2 done, Tailscale as the next tunnel milestone)
- Modify: `Docs/HANDOFF.md` (device-test checklist additions)

- [ ] **Step 1: `ARCHITECTURE.md`** — add after the transport/Transport-protocol discussion:

```markdown
## Dialers: how the byte stream is established

`Transport` says nothing about how bytes reach the SSH server; that's the
`Dialer` seam (`Sources/SloopKit/Net/Dialer.swift`). A dialer produces the
connected socket fd libssh2 runs over:

- `TCPDialer` — resolve and connect, the direct path.
- `CloudflareAccessDialer` — what `cloudflared access ssh` does, natively: a
  WebSocket to the Access-protected hostname carrying the raw SSH stream in
  binary frames, authenticated by the `CF_Authorization` JWT in the
  `cf-access-token` header. A `SocketPairRelay` turns the callback-shaped
  stream into a real fd. The JWT is captured by a WKWebView browser login
  (`App/Sloop/Cloudflare/AccessLoginView.swift`) and stored per hostname in
  the keychain.
- Tailscale (planned, M3) will be a third dialer over an embedded tailnet
  node.

Tunneled hosts are SSH-only: Mosh needs UDP, which neither tunnel carries.
`SSHHost.connectionMethod` selects the dialer via `TransportFactory`.
```

- [ ] **Step 2: `ROADMAP.md`** — under the current milestone list, add:

```markdown
- **Tunnels:** Cloudflare Access (dialer seam + native WebSocket carrier +
  browser SSO) is in. Next: Tailscale via embedded TailscaleKit — separate
  plan, gated on a real-device smoke test of the vendored framework
  (see Docs/superpowers/specs/2026-08-12-tunnel-integrations-design.md).
```

(Adjust placement to fit the file's existing structure; don't restructure it.)

- [ ] **Step 3: `HANDOFF.md`** — add to the device-test checklist:

```markdown
- **Cloudflare Access host (maintainer's tunnel):**
  - [ ] Add a host with method "Cloudflare Access" and the Access app hostname.
  - [ ] First connect opens the browser sheet; complete the IdP login; the
        terminal connects without re-prompting.
  - [ ] Quit + relaunch: reconnect uses the stored token (no browser).
  - [ ] Revoke the session in Zero Trust (or wait past expiry): reconnect
        shows the browser sheet again, not a hang or a raw error.
  - [ ] Confirm the Mosh toggle is disabled for the Access host.
```

- [ ] **Step 4: Commit**

```bash
git add Docs/ARCHITECTURE.md Docs/ROADMAP.md Docs/HANDOFF.md
git commit -m "Docs: dialer seam + Cloudflare Access architecture, roadmap, device checklist"
```

- [ ] **Step 5: MANUAL GATE — maintainer verifies against the real tunnel**

Cannot be automated: connect to a real host behind the maintainer's Cloudflare Tunnel per the HANDOFF checklist above. M2 is not "verified" until this passes on macOS and at least one iOS device/simulator. Report results honestly; fix-ups from this session (e.g. exact WebSocket framing quirks against the real edge) are expected and belong in this plan's branch.
