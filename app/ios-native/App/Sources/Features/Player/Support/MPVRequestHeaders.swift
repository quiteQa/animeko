import Foundation

/// 每次加载的完整 HTTP 配置; 缺失的 UA 与 Referer 用空值清除前一资源的覆盖.
struct MPVRequestHeaders: Equatable {
    let userAgent: String
    let referrer: String
    let fields: [String]

    init(_ headers: [String: String]) {
        var userAgent = ""
        var referrer = ""
        var fields: [String] = []
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            guard !key.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }),
                  !value.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) else { continue }
            switch key.lowercased() {
            case "user-agent": userAgent = value
            case "referer": referrer = value
            default:
                fields.append("\(key): \(value)")
            }
        }
        self.userAgent = userAgent
        self.referrer = referrer
        self.fields = fields
    }
}
