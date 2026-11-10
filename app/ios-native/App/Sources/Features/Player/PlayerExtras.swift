import AniCore
import SwiftUI
import UIKit

/// 画质增强档位, 名称与菜单顺序同上游 `VideoEnhancementMode`. 原始值即 `MPVPlayer.setEnhancement` 的档位.
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
                ExternalLinksMenuContent(model: model)
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
}

/// 「外部链接」子菜单的内容: 复制或访问视频流与数据源页面.
struct ExternalLinksMenuContent: View {
    let model: PlayerModel

    @Environment(\.openURL) private var openURL

    var body: some View {
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let rows = PlayerStatsRows.capture(model: model)
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
    }
}

/// 播放信息的各行, 从 mpv 的属性读取.
enum PlayerStatsRows {
    struct Row {
        let label: String
        let value: String
    }

    @MainActor
    static func capture(model: PlayerModel) -> [Row] {
        let player = model.player
        var rows: [Row] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { rows.append(Row(label: label, value: value)) }
        }

        let hwdec = player.string("hwdec-current")
        add("后端", "mpv (\(hwdec.map { $0 == "no" ? "软件解码" : "硬件解码 \($0)" } ?? "未加载")) · \(model.enhancementMode.title)")
        add("状态", state(model: model))
        add("标题", model.playable?.title)
        add("数据源", model.selected.map { model.sourceName($0.mediaSourceId) })
        add("进度", "\(TimeText.format(model.currentTime)) / \(TimeText.format(model.duration))")
        if let width = player.double("video-params/w"), let height = player.double("video-params/h"), width > 0 {
            add("分辨率", "\(Int(width))×\(Int(height))")
        }
        if let fps = player.double("estimated-vf-fps") ?? player.double("container-fps"), fps > 0 {
            add("帧率", "\(decimal(fps)) fps")
        }
        add("视频编码", player.string("video-codec"))
        add("视频码率", bitrate(player.double("video-bitrate")))
        add("音频编码", player.string("audio-codec-name"))
        add("播放速度", "\(decimal(Double(model.playbackRate)))x")
        add("实时输入", bitrate(player.cacheSpeed * 8))
        if let cached = player.double("demuxer-cache-duration"), cached > 0 {
            add("缓冲", "\(decimal(cached)) 秒")
        }
        let dropped = Int(player.double("frame-drop-count") ?? 0) + Int(player.double("decoder-frame-drop-count") ?? 0)
        add("解码统计", dropped > 0 ? "丢帧 \(dropped)" : nil)
        return rows
    }

    @MainActor
    private static func state(model: PlayerModel) -> String {
        let player = model.player
        guard player.hasMedia else { return "空闲" }
        if player.isBuffering { return "缓冲中" }
        return player.isPaused ? "已暂停" : "播放中"
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
