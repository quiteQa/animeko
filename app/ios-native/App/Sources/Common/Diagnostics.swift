import Darwin
import Foundation
import SwiftUI
import UIKit

/// 诊断日志: 关键步骤的记录, 以及崩溃时的信号, 未捕获异常与调用栈. 写入缓存目录的 `diagnostics.log`,
/// 下次启动后可在 "设置 > 诊断日志" 查看与分享. 系统没有生成崩溃报告时 (如在 LiveContainer 中运行) 用它定位问题.
enum Diagnostics {
    static let logURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("diagnostics.log")

    /// 信号处理函数只能访问全局状态, 因此文件描述符放在静态变量中.
    nonisolated(unsafe) fileprivate static var fd: Int32 = -1
    private static let lock = NSLock()
    private static let maxBytes = 256 * 1024

    /// 在 App 启动时调用一次.
    static func install() {
        trimIfNeeded()
        fd = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        log("===== 启动 \(version), iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)")
        NSSetUncaughtExceptionHandler { exception in
            Diagnostics.log(
                "!!! 未捕获的异常 \(exception.name.rawValue): \(exception.reason ?? "")\n"
                    + exception.callStackSymbols.joined(separator: "\n"),
            )
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig, crashSignalHandler)
        }
    }

    /// 记录一行. 立即写入磁盘, 崩溃前的最后一步也能保留.
    static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        let line = "\(timestamp()) \(message)\n"
        line.utf8CString.withUnsafeBufferPointer { buffer in
            _ = write(fd, buffer.baseAddress, buffer.count - 1)
        }
        fsync(fd)
    }

    static func read() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        ftruncate(fd, 0)
    }

    private static func trimIfNeeded() {
        guard let data = try? Data(contentsOf: logURL), data.count > maxBytes else { return }
        try? data.suffix(maxBytes / 2).write(to: logURL)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}

/// 崩溃信号: 写下信号编号与调用栈, 然后按默认方式结束进程 (仍会生成系统崩溃报告, 如果系统会生成的话).
private func crashSignalHandler(_ sig: Int32) {
    let fd = Diagnostics.fd
    if fd >= 0 {
        var header: [UInt8] = Array("\n!!! 收到崩溃信号 ".utf8)
        header.append(contentsOf: Array(String(sig).utf8))
        header.append(contentsOf: Array("\n".utf8))
        _ = header.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let count = backtrace(&frames, Int32(frames.count))
        backtrace_symbols_fd(&frames, count, fd)
        fsync(fd)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

/// 设置中的 "诊断日志" 页面.
struct DiagnosticsScreen: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "暂无记录" : text)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .defaultScrollAnchor(.bottom)
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: Diagnostics.logURL) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("清空", systemImage: "trash", role: .destructive) {
                    Diagnostics.clear()
                    text = ""
                }
            }
        }
        .task { text = Diagnostics.read() }
        .refreshable { text = Diagnostics.read() }
    }
}
