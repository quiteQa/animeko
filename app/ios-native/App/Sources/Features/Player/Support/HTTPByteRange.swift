import Foundation

/// 单段 HTTP Range 的解析结果. count 为字节数, end 为闭区间末端.
struct HTTPByteRange: Equatable, Sendable {
    enum Invalid: Error { case unsatisfiable }
    let offset: Int64
    let count: Int64
    let total: Int64
    let partial: Bool
    var end: Int64 { offset + count - 1 }
    var contentRange: String { "bytes \(offset)-\(end)/\(total)" }

    static func resolve(_ header: String?, size: Int64) throws -> Self {
        guard size >= 0 else { throw Invalid.unsatisfiable }
        guard let header else { return Self(offset: 0, count: size, total: size, partial: false) }
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes="), size > 0 else { throw Invalid.unsatisfiable }
        let pair = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard pair.count == 2 else { throw Invalid.unsatisfiable }
        func number(_ text: Substring) -> Int64? {
            guard !text.isEmpty, text.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            return Int64(text)
        }
        if pair[0].isEmpty {
            guard let suffix = number(pair[1]), suffix > 0 else { throw Invalid.unsatisfiable }
            let count = min(suffix, size)
            return Self(offset: size - count, count: count, total: size, partial: true)
        }
        guard let start = number(pair[0]), start < size else { throw Invalid.unsatisfiable }
        let end: Int64
        if pair[1].isEmpty { end = size - 1 }
        else {
            guard let requested = number(pair[1]), requested >= start else { throw Invalid.unsatisfiable }
            end = min(requested, size - 1)
        }
        return Self(offset: start, count: end - start + 1, total: size, partial: true)
    }
}
