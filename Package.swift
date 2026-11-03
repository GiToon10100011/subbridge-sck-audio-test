// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sckaudio",
    platforms: [.macOS(.v13)],  // SCStreamConfiguration.capturesAudio 최소 버전
    targets: [
        .executableTarget(name: "sckaudio")
    ]
)
