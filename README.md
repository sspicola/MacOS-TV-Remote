# TV Remote

Control the Apple TVs in your house from your Mac's menu bar. Navigate, change
volume, switch TVs, or open an app with one click.

[Download TV Remote](https://github.com/sspicola/MacOS-TV-Remote/releases/latest)

## Install

Requires macOS 14 or later and an Apple TV on the same local network. The universal
build supports Apple silicon and Intel Macs.

1. Download the ZIP from [Releases](https://github.com/sspicola/MacOS-TV-Remote/releases).
2. Unzip it and move `TV Remote.app` to Applications.
3. Open the app, then click its Apple TV icon in the menu bar.
4. If macOS asks, allow Local Network access. Choose a TV and enter the
   four-digit code shown on it. Pair each TV separately.

The current release is ad-hoc signed and has not been notarized by Apple. If
macOS blocks it, try opening it once, then use System Settings → Privacy &
Security → Open Anyway if you trust the download. See Apple's
[first-open instructions](https://support.apple.com/en-us/102445). You can also
build it yourself using the steps below.

To check a download, save its `.sha256` file in the same folder and run
`shasum -a 256 -c TV-Remote-0.3.0-universal.zip.sha256`.

## Use it

The Remote tab has a directional pad, Select, Back, Home, play/pause, and volume
buttons. Arrow keys navigate, Return selects, and Space toggles playback while
this tab is open. Volume commands go through Apple TV to your existing TV and
audio setup; support depends on that equipment.

The Apps tab shows the selected TV's installed apps. Search by name or click a
tile to launch it. Refresh the list after installing or removing apps on the TV.
A checkmark means Apple TV accepted the launch request.

Choose another TV from the dropdown to switch rooms. TV Remote remembers the
last connected TV and reconnects on launch or after the Mac wakes from sleep.
The options menu has Refresh, Reconnect, and Quit. To start it
at login, add it in System Settings → General → Login Items.

## Connection problems

Keep the Mac and Apple TV on the same local network. Guest Wi-Fi, VPN routing,
and network isolation can prevent discovery. On macOS versions that show Local
Network permissions, check System Settings → Privacy & Security → Local Network.

If pairing fails or the code expires, choose Try Again for a fresh code. Use
Reconnect after a dropped connection. If an app-launch request times out, check
the TV before retrying: the app may have opened even if its reply was lost.

TV Remote uses an unofficial Apple TV protocol. A tvOS update may require a
compatibility fix. This version does not include Siri, now-playing information,
or a separate Sonos integration.

## Privacy

Pairing credentials stay in your Mac's Keychain. Remote commands and installed
app lists travel over your local network. TV Remote remembers the last TV in
local preferences and has no account, analytics, or update-check service.

When you open Apps, TV Remote requests icons from Apple's App Store using each
app's bundle identifier and your Mac's region. It caches downloaded artwork and
uses a placeholder when no icon is available. Icon requests do not use saved
HTTP credentials or cookies.

## Build from source

Requires Swift 6.2 or later, supplied by Xcode 26 or newer Command Line Tools.
The first build downloads the dependencies pinned in `Package.resolved`.

```sh
git clone https://github.com/sspicola/MacOS-TV-Remote.git
cd MacOS-TV-Remote
./scripts/build-app.sh
open "build/TV Remote.app"
```

Copy the app to Applications to keep it installed. The build script creates a
bundle for the current Mac's architecture. To build the universal ZIP and its
checksum, run `./scripts/package-release.sh`. See [Releasing](docs/RELEASING.md)
for signing and notarization.

```sh
./scripts/test.sh
open -n "build/TV Remote.app" --args --demo --preview-window
```

The demo uses fictional rooms and does not discover or control TVs. The
`--preview-window` flag opens a regular window for UI work; normal launches use
the menu bar. Protocol tests require full Xcode:

```sh
swift test --package-path Vendor/ItsytvCore --scratch-path .build/vendor-tests --force-resolved-versions
```

`Sources/RemoteKit` holds connection state and command routing.
`Sources/TVRemote` contains the SwiftUI interface and protocol adapter. The
vendored [ItsytvCore](Vendor/ItsytvCore) library handles Apple TV pairing and
commands; its [local changes](Vendor/ItsytvCore/LOCAL_CHANGES.md) describe the
patches used here. CI builds and tests on Apple silicon and Intel Macs.

## License and credits

MIT, © 2026 Sam Spicola. See [LICENSE](LICENSE).

Apple TV support comes from Nick Ustinov's
[ItsytvCore](https://github.com/nickustinov/itsytv-core), which credits
[pyatv](https://github.com/postlund/pyatv) for protocol work. Dependency licenses
are listed in [Third-party software](THIRD_PARTY_NOTICES.md) and included in the
app bundle. This project is not affiliated with Apple.
