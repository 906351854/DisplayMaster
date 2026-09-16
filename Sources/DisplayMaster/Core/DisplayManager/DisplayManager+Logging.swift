import AppKit
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

/// 自动规则日志的落盘参数。
private enum RuleLog {
    static let maxBytes = 192 * 1024
}

extension DisplayManager {
    // MARK: - 规则日志


    private var ruleLogURL: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent(AppInfo.name, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("auto-rule.log")
    }

    /// 日志文件的绝对路径（`--auto-log` 里打印给用户看）
    var ruleLogPath: String { ruleLogURL?.path ?? "(取不到 Application Support 目录)" }

    func ruleLog(_ message: String) {
        guard let url = ruleLogURL else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        let line = "[\(fmt.string(from: Date()))] \(message)\n"
        let fm = FileManager.default

        // 超上限就把前一半砍掉，保留最近的记录
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > RuleLog.maxBytes,
           let data = try? Data(contentsOf: url) {
            try? data.suffix(RuleLog.maxBytes / 2).write(to: url)
        }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// 读回最近若干条（`--auto-log`，也方便用户直接复制出来）
    func recentRuleLog(lines: Int = 60) -> [String] {
        guard let url = ruleLogURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).map(String.init)
    }
}
