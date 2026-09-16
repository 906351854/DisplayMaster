import Foundation

/// 应用元信息。版本号只在这里维护一次，build.sh 会自动读出来写进 Info.plist。
enum AppInfo {
    static let name = "Display Master"
    static let version = "1.4.3"

    /// 迭代快、接口还没定型的阶段。挂在「关于」面板、菜单项和状态栏提示上，
    /// 让人一眼知道这是快速演进版。转正时改成 false，所有展示位一起消失。
    static let isBeta = true

    /// 展示用名字（仅用于界面；写日志目录、PM 断言名这些**标识性**场景仍用 name，
    /// 免得改个徽章把日志路径和数据都换了）。
    static var displayName: String { isBeta ? "\(name) (Beta)" : name }

    /// 展示用版本号：Beta 阶段跟着名字一起标出来
    static var displayVersion: String { isBeta ? "\(bundleVersion) (Beta)" : bundleVersion }

    static let repoURL = "https://github.com/906351854/DisplayMaster"

    /// 构建时写入 Info.plist 的版本号；直接跑二进制（非 .app）时取不到，用上面的常量兜底
    static var bundleVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? version
    }
}
