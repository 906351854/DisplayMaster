import Foundation

/// 所有 `UserDefaults` 键集中在这里。
///
/// **字符串值一个都不能改。** 它们已经落在用户的偏好文件里，改了就等于把「已关闭
/// 显示器」的记录、记住的内屏 id、名字缓存全部丢掉 —— 而这个功能的失败形态是
/// 用户面前一块黑屏、菜单里连它的卡片都没有。所以这里只做收口，值一律保持原样，
/// 包括早期版本留下的单值键。
enum DefaultsKey {
    /// 被本应用关闭的显示器记录（id -> 记录），见 `DisplayManager.disabled`
    static let disabledDisplays = "disabledDisplays"
    /// 记住的内屏 displayID（1.4.0 及更早的单值形式，读取时仍要兼容）
    static let knownBuiltinDisplayID = "knownBuiltinDisplayID"
    /// 记住的内屏 displayID 历史（1.4.1 起的多值形式）
    static let knownBuiltinDisplayIDs = "knownBuiltinDisplayIDs"
    /// 显示器名称缓存（id -> 名字）。显示器离线后 CoreGraphics 查不到名字，靠它兜底
    static let displayNames = "displayNames"
    /// 分辨率菜单是否展示全部档位
    static let showAllResolutions = "showAllResolutions"
    /// 有外接屏时自动关闭内置屏
    static let autoDisableBuiltinWhenExternal = "autoDisableBuiltinWhenExternal"
}
