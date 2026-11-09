import AniCore
import AVFoundation
import SwiftUI
import UIKit

/// 画质增强档位, 与上游 `VideoEnhancementMode` 一致. 原始值即 `EnhancedPlayerView` 的 mode.
enum VideoEnhancementMode: Int, CaseIterable, Identifiable {
    case off = 0
    case performance = 1
    case quality = 2

    var id: Int { rawValue }

    /// 菜单中的顺序与上游相同: 性能优先, 最高质量, 关闭.
    static let menuOrder: [VideoEnhancementMode] = [.performance, .quality, .off]

    var title: String {
        switch self {
        case .off: "关闭"
        case .performance: "性能优先"
        case .quality: "最高质量"
        }
    }

    /// 由设置值 (`OFF`, `PERFORMANCE`, `QUALITY`) 创建.
    init(setting: String) {
        switch setting {
        case "PERFORMANCE": self = .performance
        case "QUALITY": self = .quality
        default: self = .off
        }
    }

    var settingValue: String {
        switch self {
        case .off: "OFF"
        case .performance: "PERFORMANCE"
        case .quality: "QUALITY"
        }
    }
}

// MARK: - 更多选项

/// 播放器右上角的「更多选项」菜单: 画质增强, 播放信息, 外部链接与下载. 内嵌与全屏共用.
struct PlayerMoreMenu<Label: View>: View {
    @Bindable var model: PlayerModel
    @ViewBuilder let label: Label

    @Environment(\.openURL) private var openURL

    var body: some View {
        Menu {
            Picker(selection: $model.enhancementMode) {
                ForEach(VideoEnhancementMode.menuOrder) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                SwiftUI.Label("画质增强", systemImage: "sparkles")
            }
            .pickerStyle(.menu)

            Button(
                model.showsStats ? "隐藏播放信息" : "显示播放信息",
                systemImage: "chart.bar.xaxis",
            ) {
                model.showsStats.toggle()
            }

            Menu {
                externalLinks
            } label: {
                SwiftUI.Label("外部链接", systemImage: "arrow.up.forward.app")
            }

            Button("下载", systemImage: "arrow.down.circle") {
                model.downloadSelected()
            }
            .disabled(model.selected == nil)
        } label: {
            label
        }
        .accessibilityLabel("更多选项")
    }

    @ViewBuilder
    private var externalLinks: some View {
        let links = ExternalLinks(model: model)
        if let stream = links.stream {
            Section("视频流链接") {
                Button("复制视频流链接", systemImage: "doc.on.doc") { copy(stream) }
                Button("访问视频流链接", systemImage: "arrow.up.right") { open(stream) }
            }
        }
        if let page = links.page {
            Section("数据源页面") {
                Button("复制数据源页面链接", systemImage: "doc.on.doc") { copy(page) }
                Button("访问数据源页面", systemImage: "safari") { open(page) }
            }
        }
        if links.stream == nil, links.page == nil {
            Text("暂无可用链接")
        }
    }

    private func copy(_ url: String) {
        UIPasteboard.general.string = url
        model.toastMessage = "已复制链接"
    }

    private func open(_ url: String) {
        guard let target = URL(string: url) else { return }
        openURL(target) { accepted in
            if !accepted {
                UIPasteboard.general.string = url
                model.toastMessage = "无法打开链接，已将链接复制到剪贴板"
            }
        }
    }
}

/// 当前资源的外部链接: 解析出的原始视频流地址与数据源网页.
struct ExternalLinks {
    let stream: String?
    let page: String?

    @MainActor
    init(model: PlayerModel) {
        stream = model.playable.map(\.sourceUrl).flatMap(Self.webURL)
        page = model.selected.map(\.originalUrl).flatMap(Self.webURL)
    }

    /// 只保留 http(s) 地址; 本地文件等不对外展示.
    static func webURL(_ value: String) -> String? {
        guard let scheme = URL(string: value)?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return value
    }
}

// MARK: - 播放信息

/// 叠在画面左上角的播放信息, 每秒刷新. 内容对应上游 `PlayerStatsOverlay`.
struct PlayerStatsOverlay: View {
    let model: PlayerModel

    @State private var codecs = Codecs()

    struct Codecs: Equatable {
        var video: String?
        var audio: String?
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let rows = PlayerStatsRows.capture(model: model, codecs: codecs)
            VStack(alignment: .leading, spacing: 3) {
                Text("播放信息")
                    .fontWeight(.semibold)
                ForEach(rows, id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.label).foregroundStyle(.white.opacity(0.72))
                        Text(row.value).lineLimit(2)
                    }
                }
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.72), in: .rect(cornerRadius: 10))
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .task(id: model.playable?.url) {
            codecs = Codecs()
            // HLS 的轨道在开始播放后才出现, 拿到编码前每 2 秒重试
            for _ in 0..<10 {
                let loaded = await Self.loadCodecs(model.player.currentItem)
                if loaded.video != nil || loaded.audio != nil {
                    codecs = loaded
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
            }
        }
    }

    private static func loadCodecs(_ item: AVPlayerItem?) async -> Codecs {
        guard let item else { return Codecs() }
        var result = Codecs()
        var tracks: [AVAssetTrack] = (try? await item.asset.load(.tracks)) ?? []
        if tracks.isEmpty {
            tracks = item.tracks.compactMap(\.assetTrack)
        }
        for track in tracks {
            guard let description = (try? await track.load(.formatDescriptions))?.first else { continue }
            let name = codecName(CMFormatDescriptionGetMediaSubType(description))
            switch track.mediaType {
            case .video: result.video = result.video ?? name
            case .audio: result.audio = result.audio ?? name
            default: break
            }
        }
        return result
    }

    private static func codecName(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let fourCC = (String(bytes: bytes, encoding: .ascii) ?? "").trimmingCharacters(in: .whitespaces)
        switch fourCC {
        case "avc1", "avc3": return "H.264 (\(fourCC))"
        case "hvc1", "hev1": return "HEVC (\(fourCC))"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "mp4a": return "AAC"
        case "ac-3": return "AC-3"
        case "ec-3": return "E-AC-3"
        case "opus": return "Opus"
        case "fLaC": return "FLAC"
        default: return fourCC.isEmpty ? "未知" : fourCC
        }
    }
}

/// 播放信息的各行, 从 `AVPlayer` 及其 access log 读取.
enum PlayerStatsRows {
    struct Row {
        let label: String
        let value: String
    }

    @MainActor
    static func capture(model: PlayerModel, codecs: PlayerStatsOverlay.Codecs) -> [Row] {
        let player = model.player
        let item = player.currentItem
        let event = item?.accessLog()?.events.last
        var rows: [Row] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { rows.append(Row(label: label, value: value)) }
        }

        add("后端", model.enhancementMode == .off ? "AVPlayer" : "AVPlayer + Metal (\(model.enhancementMode.title))")
        add("状态", state(player: player, item: item))
        add("标题", model.playable?.title)
        add("数据源", model.selected.map { model.sourceName($0.mediaSourceId) })
        add("进度", "\(TimeText.format(model.currentTime)) / \(TimeText.format(model.duration))")
        if let size = item?.presentationSize, size.width > 0, size.height > 0 {
            add("分辨率", "\(Int(size.width))×\(Int(size.height))")
        }
        let frameRate = item?.tracks
            .first { $0.assetTrack?.mediaType == .video }?
            .currentVideoFrameRate ?? 0
        if frameRate > 0 { add("帧率", "\(decimal(Double(frameRate))) fps") }
        add("视频编码", codecs.video)
        add("视频码率", bitrate(event?.indicatedBitrate))
        add("音频编码", codecs.audio)
        let rate = player.rate > 0 ? player.rate : player.defaultRate
        add("播放速度", "\(decimal(Double(rate)))x")
        add("实时输入", bitrate(event?.observedBitrate))
        var decode: [String] = []
        if let dropped = event?.numberOfDroppedVideoFrames, dropped > 0 { decode.append("丢帧 \(dropped)") }
        if let stalls = event?.numberOfStalls, stalls > 0 { decode.append("卡顿 \(stalls)") }
        add("解码统计", decode.isEmpty ? nil : decode.joined(separator: " / "))
        return rows
    }

    @MainActor
    private static func state(player: AVPlayer, item: AVPlayerItem?) -> String {
        if item?.status == .failed { return "错误" }
        guard item != nil else { return "空闲" }
        switch player.timeControlStatus {
        case .playing: return "播放中"
        case .paused: return "已暂停"
        case .waitingToPlayAtSpecifiedRate: return "缓冲中"
        @unknown default: return "未知"
        }
    }

    private static func bitrate(_ value: Double?) -> String? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value >= 1_000_000 ? "\(decimal(value / 1_000_000)) Mbps" : "\(Int((value / 1000).rounded())) kbps"
    }

    private static func decimal(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}
