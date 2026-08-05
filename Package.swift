// swift-tools-version: 5.9
import PackageDescription

// SloopKit is the platform-agnostic core of Sloop: transports, session and host
// models, and the SSH/Mosh plumbing. It depends only on Foundation so it builds
// and unit-tests on any platform (including Linux CI), independent of the
// SwiftUI/SwiftTerm app layer under App/.
let package = Package(
    name: "SloopKit",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SloopKit", targets: ["SloopKit"]),
    ],
    targets: [
        .target(name: "SloopKit"),
        .testTarget(name: "SloopKitTests", dependencies: ["SloopKit"]),
    ]
)
