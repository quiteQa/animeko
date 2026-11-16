import Foundation

/// 弹幕内容与筛选设置的身份; 播放进度变化不改变它.
struct DanmakuRenderKey: Equatable {
    var revision: UUID
    var disabledSources: Set<String>
    var showsTop: Bool
    var showsBottom: Bool
    var showsFloating: Bool
}
