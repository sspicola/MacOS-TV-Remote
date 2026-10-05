# Releasing TV Remote

Use Xcode 26 for universal releases. Newer toolchains may omit the Intel
compatibility libraries. Set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
when Command Line Tools are selected and you want to use that Xcode installation.
The app runs on macOS 14 or later. GitHub Actions tests on Apple silicon and Intel Macs.

1. Update both version fields in `Resources/Info.plist` and add release notes in `docs/releases/`.
2. Run `./scripts/test.sh`. With full Xcode, also run the vendored suite:
   `swift test --package-path Vendor/ItsytvCore --scratch-path .build/vendor-tests --force-resolved-versions`.
3. Run `./scripts/package-release.sh`. It builds both architectures, includes
   license notices, signs the app, and verifies the extracted ZIP. The archive
   and SHA-256 checksum are written to `dist/`.
4. Open the extracted app on a Mac without this checkout. Check discovery,
   pairing, TV switching, controls, app search, and app launch on a real TV.
   Volume depends on the TV's audio setup.
5. Commit the changes, wait for CI, then tag the commit and upload the ZIP and
   checksum to a GitHub release. Use the corresponding file in `docs/releases/`
   as the release body.

The default build uses an ad-hoc signature. It is not notarized, and recipients
may need the first-open exception described in the README. Do not describe that
build as Developer ID signed or notarized.

For a notarized release, set the name of an installed Developer ID Application
certificate and an existing `notarytool` Keychain profile:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARYTOOL_PROFILE='tv-remote-notary' \
./scripts/package-release.sh
```

The script enables the hardened runtime, waits for Apple's acceptance, staples
the ticket, and checks it before creating the final ZIP. A failed submission
stops packaging. See Apple's [notarization guide](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
for certificate and Keychain profile setup. Keep certificates, private keys,
passwords, and pairing credentials out of the repository.

`ARCHS`, `CONFIGURATION`, and `OUTPUT_DIR` customize `build-app.sh`; for example,
`ARCHS='arm64 x86_64' ./scripts/build-app.sh` creates a universal local build.
The release script always uses both architectures and the release configuration.
Regenerate the Finder icon with `./scripts/generate-icon.sh` when its source changes.
