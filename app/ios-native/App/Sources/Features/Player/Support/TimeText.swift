import Foundation

enum TimeText {
    static func format(_ seconds: TimeInterval) -> String {
        guard seconds > 0, let total = Int(exactly: seconds.rounded(.towardZero)) else { return "0:00" }
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
