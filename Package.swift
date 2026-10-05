// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TVRemote",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TVRemote", targets: ["TVRemote"])],
    dependencies: [.package(path: "Vendor/ItsytvCore")],
    targets: [
        .target(name: "RemoteKit"),
        .executableTarget(name: "TVRemote", dependencies: [
            "RemoteKit", .product(name: "ItsytvCore", package: "ItsytvCore")
        ]),
        .testTarget(name: "RemoteKitTests", dependencies: ["RemoteKit"])
    ],
    swiftLanguageModes: [.v5]
)
