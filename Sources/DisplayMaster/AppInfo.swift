import Foundation

/// 应用元信息。版本号只在这里维护一次，build.sh 会自动读出来写进 Info.plist。
enum AppInfo {
    static let name = "Display Master"
    static let version = "1.4.0"
    static let repoURL = "https://github.com/906351854/DisplayMaster"

    /// 构建时写入 Info.plist 的版本号；直接跑二进制（非 .app）时取不到，用上面的常量兜底
    static var bundleVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? version
    }
}
