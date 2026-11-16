import AniCore

/// 收藏类型在界面上的文案与图标.
extension AniCollectionType {
    /// 收藏列表与菜单中的顺序
    static let selectable: [AniCollectionType] = [.doing, .wish, .done, .onHold, .dropped]

    var title: String {
        switch self {
        case .wish: "想看"
        case .doing: "在看"
        case .done: "看过"
        case .onHold: "搁置"
        case .dropped: "抛弃"
        default: "未收藏"
        }
    }

    var systemImage: String {
        switch self {
        case .wish: "heart"
        case .doing: "play.circle"
        case .done: "checkmark.circle"
        case .onHold: "pause.circle"
        case .dropped: "xmark.circle"
        default: "plus.circle"
        }
    }
}

extension AniCollectionItem {
    /// 续看状态的一行说明.
    var progressText: String {
        switch continueKind {
        case .notStarted: "尚未观看"
        case .notOnAir: continueEpisode.isEmpty ? "尚未开播" : "\(continueEpisode) 开播"
        case .inProgress: "下一集 \(continueEpisode)"
        case .caughtUp: "已看到 \(continueEpisode), 等待更新"
        case .completed: "已看完"
        default: ""
        }
    }
}
