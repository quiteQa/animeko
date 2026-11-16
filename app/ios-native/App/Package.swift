// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NativePlaybackSupport",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "NativePlaybackSupport",
            path: "Sources/Features",
            exclude: ["Account", "Collection", "Comments", "Downloads", "Explore", "Search", "Settings", "Subject", "WatchTogether",
                      "Danmaku/DanmakuOverlayView.swift", "Player/EpisodePlayerPage.swift", "Player/MPVBackend.swift",
                      "Player/MPVPlayer.swift", "Player/ManualBrowseModel.swift", "Player/ManualBrowsePage.swift",
                      "Player/PlayerControls.swift", "Player/PlayerExtras.swift", "Player/PlayerModel.swift",
                      "Player/PlayerScreen.swift", "Player/PlayerSurface.swift", "Player/SourcePickerSheet.swift"],
            sources: ["Player/Support", "Danmaku/DanmakuTrackAllocator.swift", "Danmaku/DanmakuRenderKey.swift"]
        ),
        .testTarget(name: "NativePlaybackSupportTests", dependencies: ["NativePlaybackSupport"], path: "Tests"),
    ],
    swiftLanguageModes: [.v5]
)
