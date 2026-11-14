import AniCore
import SafariServices
import SwiftUI

/// Bangumi 授权登录的状态. Kotlin 侧给出授权页地址并轮询结果; 授权页在 App 内的 Safari 中打开.
@MainActor
@Observable
final class BangumiLoginModel {
    /// 正在展示的授权页
    var authorizationURL: URL?
    private(set) var isRunning = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    func start(core: AniClient) {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        task = Task {
            // 序列在登录结束时完成; 任务被取消 (关闭授权页) 时提前结束, 不提示错误
            for await event in core.bangumiLogin() {
                if let url = event.openUrl.flatMap(URL.init(string:)) {
                    authorizationURL = url
                } else if event.finished, !event.success {
                    errorMessage = Self.describe(event.error)
                }
            }
            isRunning = false
            authorizationURL = nil
        }
    }

    /// 用户关闭了授权页: 放弃本次登录.
    func cancel() {
        task?.cancel()
    }

    private static func describe(_ reason: String?) -> String {
        switch reason {
        case "NetworkError": "网络错误, 请检查网络后重试"
        case "ServiceUnavailable": "服务暂时不可用, 请稍后重试"
        default: "登录失败, 请重试"
        }
    }
}

/// 在任意视图上挂载登录流程: 授权页以 Safari sheet 展示, 用户关闭即取消.
struct BangumiLoginPresenter: ViewModifier {
    @Bindable var model: BangumiLoginModel

    func body(content: Content) -> some View {
        content.sheet(
            isPresented: Binding(
                get: { model.authorizationURL != nil },
                set: { presented in
                    if !presented, model.isRunning { model.cancel() }
                },
            ),
        ) {
            if let url = model.authorizationURL {
                SafariView(url: url).ignoresSafeArea()
            }
        }
    }
}

extension View {
    func bangumiLogin(_ model: BangumiLoginModel) -> some View {
        modifier(BangumiLoginPresenter(model: model))
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
