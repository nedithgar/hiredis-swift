# hiredis-swift

`hiredis-swift` is an unofficial, source-based Swift Package Manager wrapper
around the official [`redis/hiredis`](https://github.com/redis/hiredis) C
client. It vendors hiredis **1.4.1** and provides a deliberately small Swift 6
API for sandboxed macOS applications.

This package is not endorsed, supported, or certified by Redis.

## Requirements and package shape

- macOS 26 or later
- Swift 6 language mode and an Xcode toolchain containing the macOS 26 SDK
- No separately installed hiredis, Redis, OpenSSL, package-manager library, or
  runtime downloader

`CHiredis` compiles the pinned C sources directly into the consuming product.
`Hiredis` supplies immutable Swift values and the serialized connection API.
SwiftPM links the C objects statically; the package does not create or embed a
standalone hiredis dynamic library.

## Dependency usage

For a local checkout, add the package by path:

```swift
dependencies: [
    .package(path: "../hiredis-swift")
]
```

Then depend on the library product:

```swift
.target(
    name: "MyMacApp",
    dependencies: [
        .product(name: "Hiredis", package: "hiredis-swift")
    ]
)
```

For a remote dependency, use this repository's URL and a published semantic
version requirement:

```swift
.package(url: "https://github.com/nedithgar/hiredis-swift.git", from: "0.1.0")
```

The package's current release version lives in `VERSION`, which is the single
source of truth for release automation. After the SwiftPM, Xcode, and real Redis
contract jobs pass on `main`, CI creates the matching semantic-version tag and
GitHub release only when they do not already exist. Bump `VERSION` to publish a
new release; leaving it unchanged makes the release job a no-op.

## Connect and ping

```swift
import Hiredis

let configuration = try HiredisConfiguration(
    hostname: "127.0.0.1",
    port: 6379,
    username: "default",
    password: passwordFromKeychain,
    database: 0,
    connectionTimeout: .seconds(3),
    commandTimeout: .seconds(2),
    protocolVersion: .resp3
)

let connection = HiredisConnection(configuration: configuration)
try await connection.connect()
let pong = try await connection.ping()
await connection.close()
```

`connect()` rejects an already-open connection. `close()` is idempotent and
immediately invalidates the owned context. `reconnect()` closes any current
context, opens a fresh one, and repeats authentication, RESP negotiation, and
database selection. Commands do not reconnect implicitly after a transport,
timeout, cancellation, or protocol failure.

Configuration descriptions disclose only whether credentials are configured;
they never print their values. Authentication arguments and complete command
frames are never logged. Server errors returned by `AUTH` and by `HELLO ...
AUTH ...` have their credential arguments redacted before becoming Swift
errors.

## Binary-safe commands

Every raw command uses hiredis' length-aware `redisAppendCommandArgv` API. No
argument is interpreted as a format string, and embedded null bytes are
preserved:

```swift
let key = Data("binary-key".utf8)
let value = Data([0x00, 0x41, 0x00, 0x42])

let response = try await connection.command(arguments: [
    Data("SET".utf8),
    key,
    value
])
```

`HiredisCommandResponse.reply` is the in-band response. RESP3 attribute maps
and push frames received before that response are copied into `attributes` and
`pushMessages`. All C reply storage is copied into immutable Swift values and
freed before the method returns; no unmanaged context, reply pointer, or
borrowed byte buffer crosses the public API.

## RESP2 and RESP3 values

`HiredisReply` represents every reply object kind emitted by the pinned hiredis
reader:

- binary bulk strings (`Data`), status strings, integers, doubles, Booleans,
  nulls, and server errors;
- arrays, ordered map entries, sets, and attribute maps;
- big numbers and verbatim strings with their three-byte format identifier;
- push messages.

Choose `.resp2` or `.resp3` in the configuration. RESP3 connections issue
`HELLO 3` during the handshake. Top-level server-error replies throw
`HiredisError.serverReply`; nested error replies remain `.error` values.

The pinned hiredis reader does not recognize RESP3 blob-error (`!`) frames.
They are reported as protocol failures rather than silently misrepresented.

## Concurrency, cancellation, and lifetime

`HiredisConnection` is an actor with a dedicated serial, dispatch-backed
executor. Blocking DNS, connect, read, and write work therefore never executes
on `MainActor`, and only one operation can touch a hiredis context at a time.
Each connection owns its executor, socket interrupter, and C context for an
explicit lifetime.

Task cancellation during a blocking command calls `shutdown` on that socket,
unblocks hiredis, closes the now-invalid context, and throws
`HiredisError.cancellation`. A connection attempt does not expose a usable file
descriptor to the Swift wrapper until hiredis returns, so cancellation during
synchronous hostname resolution or TCP establishment is reported only after
that work returns. The configured connection timeout applies to hiredis' TCP
readiness wait, not to synchronous DNS resolution, so slow DNS can delay
cancellation beyond the configured timeout. Cancel the active command task when
immediate shutdown is required; a separately queued `close()` waits for the
active actor operation.

Cancellation and synchronous operation completion are ordered atomically. A
task cancelled before its operation becomes active does not touch an existing
socket. Once an operation becomes active, cancellation wins by interrupting and
closing its context; once completion wins, a late or stale cancellation handler
cannot affect that context or the next operation.

Command and connection timeouts also close the affected context. Call
`reconnect()` explicitly before issuing more commands.

## TLS status

TLS is intentionally deferred in version 0.1. Upstream hiredis implements TLS
through a separate OpenSSL-dependent source and library; it does not provide a
native Apple TLS transport. Vendoring and maintaining OpenSSL solely for this
thin wrapper would substantially expand its source, security, licensing,
reproducibility, and export-compliance surface. The package never searches
Homebrew, `/usr/local`, or any system-installed OpenSSL location.

The configuration already contains `transportSecurity`; selecting `.tls`
throws `HiredisError.configuration(.tlsUnavailable)` without opening a socket,
so a future source-based implementation does not require redesigning the
connection API.

Plaintext Redis traffic, including credentials and command contents, is not
confidential. Limit non-TLS connections to trusted networks or protect them
with a separately managed secure tunnel. Do not expose a plaintext Redis port
to an untrusted network.

If TLS is added later, the consuming app must reassess App Store encryption
export declarations. Apple's current [export compliance
overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
distinguishes operating-system cryptography from third-party implementations;
the app developer remains responsible for the final determination.

## Mac App Sandbox and local network privacy

A sandboxed application must enable **Outgoing Connections (Client)**, which
sets the Boolean
[`com.apple.security.network.client`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client)
entitlement. The package initiates TCP connections and does not require the
incoming-network entitlement.

Connections to LAN hosts are subject to macOS Local Network privacy. An app
that can reach a local Redis or Valkey host—including an app that lets people
enter an arbitrary address—should add an accurate
[`NSLocalNetworkUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription)
to its `Info.plist`, sign with an Apple-issued identity, and handle denial as a
normal connection failure. See Apple's [local network privacy
technote](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
This package performs direct unicast TCP connections and does not perform
Bonjour discovery.

## Privacy manifest audit

No `PrivacyInfo.xcprivacy` is included in version 0.1. The shipped source has no
telemetry, tracking domains, advertising behavior, or data collection by the
package authors. The audit found socket/DNS/poll operations, heap allocation,
and `clock_gettime(CLOCK_MONOTONIC)` for bounded connection timing, but none of
the APIs currently enumerated by Apple in the required-reason categories. In
particular, it does not call `ProcessInfo.systemUptime`, `mach_absolute_time`,
file-timestamp APIs, disk-space APIs, active-keyboard APIs, or user defaults.

Apple updates these rules over time. Re-run the audit when updating hiredis or
adding wrapper capabilities, using Apple's [required-reason API
documentation](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
and [privacy manifest guidance](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk).
The consuming app must separately describe its own collection and use of data
sent through Redis.

## Licensing and attribution

Original wrapper and integration code is MIT-licensed; see `LICENSE`.
Vendored hiredis is BSD-3-Clause licensed except for its embedded
ffc/fast_float implementation, which uses ffc's MIT license option. The license
texts are in `LICENSES/hiredis-BSD-3-Clause.txt` and `LICENSES/ffc-MIT.txt`.
Binary redistributions must reproduce the applicable copyright notices and
license terms in their documentation or other materials.
`THIRD_PARTY_NOTICES.md` is a complete, reusable acknowledgement for that
purpose. Exact upstream provenance and the vendored-release update process are
in `UPSTREAM.md`.

## Updating the vendored release

The complete procedure is in `UPSTREAM.md`. This repository uses a Git-tracked
tag-archive vendoring workflow: Git owns the package's history, review, and
rollback, while a verified official upstream stable-tag archive is only the
reproducible source for each hiredis import. Hiredis is committed directly to
this repository; it is not a Git submodule and does not require an upstream
checkout. Download the archive into a temporary package-local directory, verify
and record its checksum and commit, replace only the enumerated core sources and
headers, compare every copied file byte-for-byte, refresh the associated license
materials, update the wrapper metadata/tests/documentation, run the full
verification matrix below, remove the temporary files, and commit the
coordinated update through this repository's normal workflow.

## Duplicate-symbol warning

`CHiredis` compiles upstream hiredis symbols such as `redisConnect` and
`freeReplyObject` into the final link. An application or another package that
also links a separate copy of hiredis can fail with duplicate symbols or,
depending on linker behavior, resolve against an unintended version. Keep one
hiredis implementation in the final product. Do not add a second static or
dynamic hiredis dependency alongside this package.

## Deliberately unsupported in 0.1

- TLS, client certificates, and certificate-validation configuration
- Unix-domain sockets
- connection pools, clusters, Sentinel discovery, and automatic failover
- command-specific convenience methods beyond `ping()`
- pipelining and transactions as wrapper concepts (arbitrary commands remain
  available through the raw API)
- subscription streams and a general asynchronous push-message stream
- custom hiredis allocators and direct access to the upstream asynchronous API
- RESP3 blob-error frames, which hiredis 1.4.1 rejects

## Verification

Normal verification is entirely local and starts no Redis or Valkey service:

```bash
swift package describe
swift build
swift test
swift build -c release
swift test -c release
xcodebuild -scheme hiredis-swift -destination 'generic/platform=macOS' build
```

The normal test target uses Swift Testing and a process-local loopback TCP
server. It covers deterministic RESP2/RESP3 fixtures, all supported reply kinds,
embedded null bytes, protocol/server errors, configuration validation, repeated
reply cleanup, close/reconnect/cancellation/timeout behavior, serialization, and
credential redaction.

`HiredisIntegrationTests` adds a small real-Redis contract suite for
authentication, RESP2/RESP3 negotiation, reconnects, database selection,
binary-safe storage, RESP3 aggregate replies, and real server errors. The suite
is compiled by normal verification but is intentionally skipped unless both
GitHub Actions and the reusable Redis integration workflow enable it. CI calls
that workflow as a required release gate; it installs and owns a disposable
loopback Redis process on its ephemeral runner. Local builds never install,
launch, or contact Redis.
