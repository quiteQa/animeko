import Foundation

/// 日志保留 URL 的协议与主机, 去除路径、用户信息、查询和片段.
enum DiagnosticRedactor {
    static func redact(_ message: String) -> String {
        var output = message
        let urlPattern = #"[A-Za-z][A-Za-z0-9+.-]*://[^\s<>\"]+"#
        if let expression = try? NSRegularExpression(pattern: urlPattern) {
            let range = NSRange(output.startIndex..., in: output)
            for match in expression.matches(in: output, range: range).reversed() {
                guard let range = Range(match.range, in: output) else { continue }
                let url = URLComponents(string: String(output[range]))
                let replacement: String
                if let scheme = url?.scheme, let host = url?.host {
                    replacement = "\(scheme)://\(host)/<redacted>"
                } else { replacement = "<redacted-url>" }
                output.replaceSubrange(range, with: replacement)
            }
        }
        let credentials = #"(?i)\b(authorization|cookie|set-cookie|access_token|refresh_token|token|password|apikey|api_key)\s*[:=]\s*[^\r\n]+"#
        if let expression = try? NSRegularExpression(pattern: credentials) {
            output = expression.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "$1=<redacted>")
        }
        return output
    }
}
