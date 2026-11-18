// swift-tools-version:5.4
import PackageDescription

let package = Package(
    name: "timeline-ml",
    platforms: [.macOS(.v11), .iOS(.v14)],
    products: [.library(name: "TimelineML", targets: ["TimelineML"])],
    targets: [
        .target(name: "TimelineML"),
        .executableTarget(name: "tml", dependencies: ["TimelineML"], exclude: ["Info.plist"],
                          // Embedded so macOS can show the speech-recognition permission dialog for a CLI.
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                                         "-Xlinker", "Sources/tml/Info.plist"])]),
        .testTarget(name: "TimelineMLTests", dependencies: ["TimelineML"]),
    ]
)
