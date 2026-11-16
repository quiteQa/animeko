import AniCore
import Foundation

// AniClient 到 Swift 的桥接由 SKIE 生成: Kotlin `suspend` 是 `async throws`, `Flow` 是可以 `for await` 的序列,
// 取消所在的 Task 即停止收集. 这里只放 SKIE 不覆盖的小工具.

extension Error {
    /// 解析失败的原因码 (`AniPlaybackException.reason`), 其他错误为 `nil`.
    var aniPlaybackReason: String? {
        let kotlinException = (self as NSError).userInfo["KotlinException"]
        return (kotlinException as? AniPlaybackException)?.reason
    }
}
