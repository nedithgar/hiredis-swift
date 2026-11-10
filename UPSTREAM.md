# Upstream hiredis provenance

## Pin

| Field | Value |
| --- | --- |
| Project | `redis/hiredis` |
| Release | `1.4.1` |
| Tag | `v1.4.1` |
| Commit | `616f2286ba5503f74ae96e720623fa11dbc690af` |
| Release page | <https://github.com/redis/hiredis/releases/tag/v1.4.1> |
| Source archive | <https://github.com/redis/hiredis/archive/refs/tags/v1.4.1.tar.gz> |
| Redirected archive host | <https://codeload.github.com/redis/hiredis/tar.gz/refs/tags/v1.4.1> |
| SHA-256 | `ca3180359a8b1275838a45415851f8cd5c411e27bdbf18f4823012e45507d2e4` |
| Retrieved | 2026-08-29 |

The archive was downloaded from the tag URL and verified locally with
`shasum -a 256` before any files were copied.

The release tag identifies hiredis 1.4.1. Its unmodified `hiredis.h` still
defines `HIREDIS_PATCH` as `0` and `HIREDIS_SONAME` as `1.4.0`; this package
does not rewrite those upstream macros. `HiredisPackage.upstreamVersion`
reports the pinned release tag, `1.4.1`.

## Vendored files

The following upstream files are copied from the archive. All remain
byte-for-byte copies except for the local `net.c` patch documented below:

- Compiled C sources: `alloc.c`, `async.c`, `hiredis.c`, `net.c`, `read.c`,
  `sds.c`, and `sockcompat.c`.
- Public headers: `alloc.h`, `async.h`, `hiredis.h`, `read.h`, `sds.h`, and
  `sockcompat.h`.
- Private build inputs: `async_private.h`, `dict.c`, `dict.h`, `ffc.h`,
  `fmacros.h`, `net.h`, `sdsalloc.h`, and `win32.h`. Upstream `async.c`
  includes `dict.c` directly, so SwiftPM does not compile `dict.c` separately.

Associated license material is recorded separately:

- Upstream `COPYING` is copied verbatim to
  `LICENSES/hiredis-BSD-3-Clause.txt`.
- The MIT option selected by the embedded, tri-licensed `ffc.h` is reproduced
  in `LICENSES/ffc-MIT.txt`.

The upstream tests, examples, benchmarks, command-line programs, build-system
metadata, event-loop adapters, and TLS/OpenSSL sources are not vendored.

## Modifications and Apple integration

One local patch is applied to `Sources/CHiredis/Vendor/hiredis/net.c`.
All other vendored sources and the copied public hiredis headers are unchanged.

`Sources/CHiredis/CHiredis.c` and `Sources/CHiredis/include/CHiredis.h` are
original MIT-licensed integration files. They configure close-on-exec sockets,
preserve RESP3 push replies for Swift conversion, expose read-only reply
accessors, and classify connect-poll expiry (`ETIMEDOUT`) and Darwin's blocking
socket timeout result (`EAGAIN` / `EWOULDBLOCK`) for the Swift
operation-specific timeout adapter. Timeout classification remains in the
integration layer.

### Darwin connection-error preservation

Darwin can return `EISCONN` from a repeated `connect()` while a failed
connection still has a pending `SO_ERROR`, such as `ECONNREFUSED`. Upstream
`redisCheckConnectDone` accepts `EISCONN` as successful completion, allowing a
later socket-configuration error to obscure the original connection failure.

The local patch reads `SO_ERROR` before repeating `connect()` and returns a
pending failure through `errno`, allowing `redisCheckSocketError` to record
the original cause. It belongs in the internal connection-completion path
because this check must precede both the repeated `connect()` and subsequent
socket configuration.

Exact diff against the pinned `v1.4.1` source (without context lines):

```diff
--- a/Sources/CHiredis/Vendor/hiredis/net.c
+++ b/Sources/CHiredis/Vendor/hiredis/net.c
@@ -338,0 +339,11 @@ int redisCheckConnectDone(redisContext *c, int *completed) {
+    int socket_error = 0;
+    socklen_t error_length = sizeof(socket_error);
+    /* Darwin can report EISCONN from a repeated connect while a failed
+     * connection still has a pending SO_ERROR. Preserve that error before
+     * interpreting connect's result or configuring the socket. */
+    if (getsockopt(c->fd, SOL_SOCKET, SO_ERROR, &socket_error, &error_length) == -1)
+        return REDIS_ERR;
+    if (socket_error != 0) {
+        errno = socket_error;
+        return REDIS_ERR;
+    }
```

`ConnectionTests.refusedConnectionPreservesSocketCause` verifies the original
refusal cause across repeated IPv4 and IPv6 connection attempts.
`ConnectionTests.connectionTimeoutPreservesOperation` separately verifies the
integration layer's connect-timeout classification and failed-context cleanup.

## Known Xcode diagnostics

Xcode 26.6's generated Swift-package scheme builds this snapshot successfully,
but its default `CLANG_WARN_SHORTEN_64_TO_32` setting reports 14 distinct
implicit narrowing warnings in the upstream C sources (`async.c`,
`hiredis.c`, `net.c`, `read.c`, and `sds.c`). A universal generic macOS build
emits each warning once per architecture, for 28 warning lines. The
corresponding `swift build`, `swift test`, and `swift build -c release` commands
complete without warnings.

The package leaves these upstream narrowing conversions unchanged and does not
add SwiftPM `unsafeFlags` to hide their diagnostics. A future upstream release
should be reevaluated for fixes before changing this policy. Consumers that
promote all C warnings to errors may need an upstream remediation before
enabling that policy for `CHiredis`.

## Git-tracked vendored updates

This repository uses a Git-tracked tag-archive vendoring workflow. Git owns the
package's history, review, and rollback; a verified official upstream tag
archive is only the reproducible source input for each hiredis import. The
vendored files are committed directly to this repository. Do not add hiredis as
a Git submodule or require an upstream Git checkout:

1. Choose a stable release from the official hiredis release page and record
   its tag and full commit identifier.
2. Download that tag archive from the official `redis/hiredis` repository into
   a temporary directory inside this package.
3. Run `shasum -a 256 <archive>` and record the exact URL and checksum above.
4. Extract the archive and review its release notes, licenses, build source
   list, installed public-header list, reply type constants, and TLS
   dependencies.
5. Replace only the files enumerated in **Vendored files**. Add or remove a file
   only when the upstream core-library build requires it. Do not copy tests,
   tools, examples, benchmarks, or unrelated adapters.
6. Compare every copied upstream file byte-for-byte with the extracted
   archive. Reevaluate the local connection-error patch above: remove it if
   upstream fixes the same behavior; otherwise reapply the required change and
   verify the IPv4 and IPv6 regression tests. Keep any unavoidable platform
   change outside the vendor directory when possible; otherwise document its
   exact diff and rationale here.
7. Replace `LICENSES/hiredis-BSD-3-Clause.txt` with the release's complete
   license. Recheck every vendored file for additional copyright holders or
   license terms, refresh or remove `LICENSES/ffc-MIT.txt` as appropriate for
   `ffc.h`, and update `THIRD_PARTY_NOTICES.md` with every applicable notice.
8. Update the release metadata, public reply conversion, tests, README, and
   `HiredisPackage.upstreamVersion`.
9. Run all verification commands documented in the README, including both
   architectures when the installed SDK supports them, and inspect the linked
   artifacts for unexpected dynamic libraries.
10. Delete the temporary archive and extraction directory.
11. Review the complete repository diff, then commit the vendored sources,
    licenses, provenance, wrapper metadata, tests, and documentation as one
    coordinated update.
