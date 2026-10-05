# ItsytvCore provenance and local changes

Vendored from [nickustinov/itsytv-core](https://github.com/nickustinov/itsytv-core)
at `052d9a9a0416d577119316ea813aa3b822b408e5`.

## License provenance

The [pinned README](https://github.com/nickustinov/itsytv-core/blob/052d9a9a0416d577119316ea813aa3b822b408e5/README.md#license)
declares MIT licensing and copyright 2026 Nick Ustinov. That revision and its
history contain no LICENSE file.

The library's [initial commit](https://github.com/nickustinov/itsytv-core/commit/b5105224a5c44614186cf4c9b66090e628f89177)
extracts the protocol library from itsytv-macos. The corresponding
[app commit](https://github.com/nickustinov/itsytv-macos/commit/51bd52f2fa5ea28fcb78d68420a71aa12fff3064)
records the move. Its parent, `bb0f682b0b6e56eef6e535b00e76c338562277ae`,
contains the full MIT license with the same copyright holder and year.
Thirty-six of the initial core's 46 source files match that app revision byte
for byte; the other ten were adapted for the package.

[LICENSE](LICENSE) is an unchanged copy of the
[originating app's license](https://github.com/nickustinov/itsytv-macos/blob/bb0f682b0b6e56eef6e535b00e76c338562277ae/LICENSE).
We added it here to retain the full license text alongside the extracted code.
Its SHA-256 is `739f3563fa3fbbbb72e40a332050f27b002fb4161e2ebfc1ed46a1b065244fb3`.
Preserve the copyright and permission notice in redistributed copies.

[ThirdPartyLicenses](ThirdPartyLicenses) contains unchanged dependency licenses
and NOTICE files for the release's root `Package.resolved`. The included
[SOURCES.json](ThirdPartyLicenses/SOURCES.json) records versions, immutable source
URLs and SHA-256 hashes. It also includes the pyatv license and the BoringSSL
license at the revision recorded by big-num's vendoring metadata. Refresh these
files when dependency revisions change. SwiftProtobuf's nested compiler licenses
are included even though this app uses the SwiftProtobuf runtime product.

## Integration contract

Call manager lifecycle and command methods on the main thread. The app uses
`AppleTVManager(enableMediaRemote: false)` for both its discovery manager and
per-device sessions. Discovery runs independently while each connection attempt
gets a fresh session manager. The app owns connection and pairing deadlines.

Companion-only sessions support navigation, Select, Back, Home, play/pause,
volume up/down and explicit app requests. They skip the AirPlay/MRP tunnel,
automatic app enumeration, virtual touch setup and keyboard listener. Mute
requires MRP. The optional MRP path has not received a full concurrency audit.

The app stores pairing credentials under Keychain service
`com.sam.TVRemote.credentials` and identifies itself to Apple TV as `TV Remote`.
No Itsytv credential entries are read or changed.

## Protocol changes

- Companion callbacks, button timers, keepalive and reconnect work run on the
  main queue. Connection identity and generation checks reject retired callbacks.
- Disconnect clears callbacks before canceling the transport, then clears pairing
  challenges, verification state, queued commands and touch continuations.
- `.pairing` means a current salt/public-key challenge is ready. PIN submission
  returns to `.connecting`. Pairing errors and credential-save failures are
  reported through `.error`.
- `.connected` requires a Companion session ID. TVRC registration or its
  two-second fallback can complete only the current session. Reconnect uses
  `.connecting`, bounded retries and explicit failures.
- Discovery stop detaches delegates and clears queued results and snapshots.
  Resolved ports are checked before conversion to UInt16.
- OPACK checks integer lengths and remaining bytes before conversion or slicing,
  rebases Data slices and limits nested containers to 64 levels. Short encrypted
  transport and handshake payloads throw errors. Transport authentication failures
  close the affected connection.

## App requests

`fetchLaunchableApps(completion:)` returns
`Result<[(bundleID: String, name: String)], Error>`.
`requestAppLaunch(bundleID:completion:)` returns `Result<Void, Error>`.
Both require a connected session and work without MRP. Completion runs on main
and is suppressed after session retirement; callers must clear their loading
state when changing devices or disconnecting.

Each request has an eight-second deadline. Reply, write failure, disconnect or
timeout completes it once and removes its handler and timer. Requests are never
replayed on another session. The legacy `fetchApps()` and `launchApp(bundleID:)`
methods remain available and log failures from the same bounded request path.

A valid empty `_c` dictionary succeeds. Missing content, malformed entries,
duplicate bundle IDs, explicit server errors and absent replies fail. Results
contain only the device's returned apps, sorted by name and bundle ID.
`AppleTVAppRequestError` distinguishes connection failures, timeout, malformed
responses, rejection, explicit lack of support and missing identifiers. Silence
means timeout; it does not establish whether the device supports the request.

Launch success means Apple TV acknowledged `_launchApp` without `_em` or a
nonzero `_ec`. It does not confirm foreground visibility. A timeout may follow a
successful launch whose acknowledgment was lost. These semantics follow pyatv's
[Companion API](https://github.com/postlund/pyatv/blob/master/pyatv/protocols/companion/api.py)
and [request exchange](https://github.com/postlund/pyatv/blob/master/pyatv/protocols/companion/protocol.py).

## Tests

The upstream suite and local regression tests cover teardown, discovery state,
request deadlines and cleanup, app response parsing, OPACK bounds and truncated
handshake payloads. Full XCTest execution requires Xcode; Command Line Tools
alone do not include its test runner. Hardware pairing, command
latency and HDMI-CEC volume still require tests on real Apple TVs.
