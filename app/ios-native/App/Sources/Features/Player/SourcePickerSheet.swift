import AniCore
import SwiftUI

/// 选源面板. "资源" 页列出候选资源并可按偏好筛选; "手动查找" 页直接浏览数据源的条目与剧集;
/// "数据源" 页显示每个数据源的查询状态并可重试.
struct SourcePickerSheet: View {
    let model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    private enum Page: Hashable { case media, manual, sources }
    @State private var page: Page = .media
    @State private var preferredOnly = true

    var body: some View {
        NavigationStack {
            Group {
                switch page {
                case .media: mediaList
                case .manual: ManualBrowsePage(player: model) { dismiss() }
                case .sources: sourceList
                }
            }
            .navigationTitle("选择资源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("页面", selection: $page) {
                        Text("资源").tag(Page.media)
                        Text("手动查找").tag(Page.manual)
                        Text("数据源").tag(Page.sources)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - 资源

    private var visibleCandidates: [AniMediaCandidate] {
        preferredOnly ? model.preferredCandidates : model.candidates
    }

    private var mediaList: some View {
        List {
            if let progress = model.progress, progress.completed < progress.total {
                Section {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1))) {
                        Text("正在查询数据源 \(progress.completed)/\(progress.total)")
                    }
                }
            }
            Section {
                Toggle("只显示符合偏好的资源", isOn: $preferredOnly)
                PreferenceFilters(model: model)
            }
            Section {
                ForEach(visibleCandidates, id: \.mediaId) { candidate in
                    Button {
                        model.select(candidate)
                        dismiss()
                    } label: {
                        CandidateRow(
                            candidate: candidate,
                            sourceName: model.sourceName(candidate.mediaSourceId),
                            isSelected: candidate.mediaId == model.selected?.mediaId,
                        )
                    }
                    .tint(.primary)
                    .disabled(!candidate.playable)
                }
            } header: {
                Text("\(visibleCandidates.count) 个资源")
            } footer: {
                if visibleCandidates.contains(where: { !$0.playable }) {
                    Text("灰色的资源在 iOS 上无法播放。")
                }
            }
            // 救援入口: 自动匹配选不出 (如名字不含集号的 OVA) 时, 手动查找是确定的出路
            Section {
                Button("找不到想看的? 手动查找") { page = .manual }
                    .font(.callout)
            }
        }
        .overlay {
            if visibleCandidates.isEmpty, model.progress.map({ $0.completed >= $0.total }) == true {
                ContentUnavailableView {
                    Label("没有资源", systemImage: "square.stack")
                } description: {
                    Text(preferredOnly && !model.candidates.isEmpty ? "没有符合偏好的资源" : "没有找到这一集的资源")
                } actions: {
                    if preferredOnly, !model.candidates.isEmpty {
                        Button("显示全部资源") { preferredOnly = false }
                    }
                    Button("手动查找") { page = .manual }
                }
            }
        }
    }

    // MARK: - 数据源

    private var sourceList: some View {
        List {
            ForEach(model.sources, id: \.instanceId) { source in
                SourceRow(source: source) { model.retrySource(source) }
            }
        }
        .overlay {
            if model.sources.isEmpty {
                ContentUnavailableView("没有启用的数据源", systemImage: "antenna.radiowaves.left.and.right.slash")
            }
        }
    }
}

/// 字幕组 / 分辨率 / 字幕语言 / 数据源 四个维度的偏好菜单.
private struct PreferenceFilters: View {
    let model: PlayerModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.preferences, id: \.key) { preference in
                    PreferenceMenu(preference: preference, model: model)
                }
            }
        }
    }
}

private struct PreferenceMenu: View {
    let preference: AniPreference
    let model: PlayerModel

    var body: some View {
        Menu {
            Button("任意") { model.setPreference(key: preference.key, value: nil) }
            Divider()
            ForEach(preference.available, id: \.self) { value in
                Button {
                    model.setPreference(key: preference.key, value: value)
                } label: {
                    if value == preference.selected {
                        Label(label(for: value), systemImage: "checkmark")
                    } else {
                        Text(label(for: value))
                    }
                }
            }
        } label: {
            Text(preference.selected.map { "\(title): \(label(for: $0))" } ?? title)
                .lineLimit(1)
        }
        .buttonStyle(.glass)
        .disabled(preference.available.isEmpty)
    }

    private var title: String {
        switch preference.key {
        case AniPreferenceKeys.shared.ALLIANCE: "字幕组"
        case AniPreferenceKeys.shared.RESOLUTION: "分辨率"
        case AniPreferenceKeys.shared.SUBTITLE_LANGUAGE: "字幕"
        case AniPreferenceKeys.shared.MEDIA_SOURCE: "数据源"
        default: preference.key
        }
    }

    private func label(for value: String) -> String {
        switch preference.key {
        case AniPreferenceKeys.shared.MEDIA_SOURCE: model.sourceName(value)
        case AniPreferenceKeys.shared.SUBTITLE_LANGUAGE: SubtitleLanguage.displayName(value)
        default: value
        }
    }
}

enum SubtitleLanguage {
    /// 上游约定的字幕语言 ID 的显示名称.
    static func displayName(_ id: String) -> String {
        switch id {
        case "CHS": "简体中文"
        case "CHT": "繁体中文"
        case "JPN", "JPY": "日语"
        case "ENG": "英语"
        default: id
        }
    }
}

private struct CandidateRow: View {
    let candidate: AniMediaCandidate
    let sourceName: String
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("正在播放")
            }
        }
        .contentShape(.rect)
    }

    private var details: String {
        [
            sourceName,
            candidate.alliance,
            candidate.resolution,
            candidate.subtitleLanguages.map(SubtitleLanguage.displayName).joined(separator: "/"),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }
}

private struct SourceRow: View {
    let source: AniMediaSourceStatus
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if canRetry {
                Button(source.state == "DISABLED" ? "启用" : "重试", action: onRetry)
                    .buttonStyle(.glass)
            }
        }
    }

    private var canRetry: Bool {
        ["FAILED", "ABANDONED", "RATE_LIMITED", "DISABLED"].contains(source.state)
    }

    private var statusText: String {
        switch source.state {
        case "SUCCEED": "找到 \(source.resultCount) 个资源"
        case "WORKING": "查询中"
        case "IDLE": "等待查询"
        case "DISABLED": "未启用"
        case "FAILED": "查询失败"
        case "ABANDONED": "已放弃"
        case "RATE_LIMITED": "请求过于频繁"
        case "CAPTCHA_REQUIRED": "需要验证码 (iOS 暂不支持)"
        default: source.state
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch source.state {
        case "WORKING", "IDLE": ProgressView()
        case "SUCCEED": Image(systemName: source.resultCount > 0 ? "checkmark.circle.fill" : "circle").foregroundStyle(.green)
        case "DISABLED": Image(systemName: "minus.circle").foregroundStyle(.secondary)
        default: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        }
    }
}
