# Third-party software

TV Remote's own code is MIT licensed. These dependencies keep their original
licenses. Release bundles include the license texts in `Contents/Resources/Licenses`.

| Project | Version or revision | License |
| --- | --- | --- |
| [ItsytvCore](https://github.com/nickustinov/itsytv-core) | `052d9a9a0416d577119316ea813aa3b822b408e5`, with local changes | MIT, Nick Ustinov |
| [SwiftProtobuf](https://github.com/apple/swift-protobuf) | 1.38.1 | Apache 2.0 with Swift Runtime Library Exception |
| [swift-srp](https://github.com/adam-fowler/swift-srp) | 2.4.0 | Apache 2.0 |
| [big-num](https://github.com/adam-fowler/big-num) | 2.0.3 | MIT; includes BoringSSL notices |
| [swift-crypto](https://github.com/apple/swift-crypto) | 4.5.2 | Apache 2.0 |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.3 | Apache 2.0 |
| [pyatv](https://github.com/postlund/pyatv) | Protocol reference credited by ItsytvCore | MIT |

The lockfile pins dependency revisions. License source URLs and checksums are in
[SOURCES.json](Vendor/ItsytvCore/ThirdPartyLicenses/SOURCES.json). The ItsytvCore
[local changes](Vendor/ItsytvCore/LOCAL_CHANGES.md) document its origin, license,
and patches. SwiftProtobuf's bundled tool licenses are preserved alongside its
runtime license, even though TV Remote does not ship the compiler tools.

App artwork belongs to its respective owners and is fetched from Apple's App
Store at runtime. This project is not affiliated with Apple or the app publishers.
